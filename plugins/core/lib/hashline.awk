# hashline.awk — line-hashing for tamper-detection anchors
# POSIX-portable: works on BWK awk, gawk, mawk
#
# Modes (set via -v mode=X):
#   format   (default) — output LINENUM#HASH:content
#   validate — check anchors against computed hashes
#   context  — like validate but show context on mismatch
#
# Variables:
#   mode       — format | validate | context
#   start_line — first line to output in format mode (default 1)
#   max_lines  — max lines to output in format mode (default unlimited)
#   anchors    — comma-separated LINE:HASH pairs for validate/context

BEGIN {
    if (mode == "") mode = "format"
    if (start_line == "") start_line = 1
    start_line += 0
    if (max_lines == "") max_lines = 0
    max_lines += 0

    NIBBLE = "ZPMQVRWSNKTXJBYH"
    MOD = 4294967296  # 2^32

    # ord lookup table
    for (i = 1; i <= 127; i++) {
        c = sprintf("%c", i)
        _ord[c] = i
    }

    # parse anchors for validate/context modes
    anchor_count = 0
    if (mode == "validate" || mode == "context") {
        n = split(anchors, parts, ",")
        for (i = 1; i <= n; i++) {
            split(parts[i], kv, ":")
            line_num = kv[1] + 0
            anchor_line[line_num] = 1
            anchor_hash[line_num] = kv[2]
            anchor_count++
        }
    }

    mismatch_found = 0
}

function hash_line(text, lineno,    stripped, has_alnum, h, j, ch, seed, byte, hi, lo) {
    # strip \r and trailing whitespace
    stripped = text
    gsub(/\r/, "", stripped)
    sub(/[ \t]+$/, "", stripped)

    # check for alphanumeric content
    has_alnum = match(stripped, /[a-zA-Z0-9]/)

    # djb2
    h = 5381
    for (j = 1; j <= length(stripped); j++) {
        ch = substr(stripped, j, 1)
        h = (h * 33 + _ord[ch]) % MOD
    }

    # mix line number for non-alnum lines
    if (!has_alnum) {
        seed = lineno
        h = (h + seed * 2654435761) % MOD
    }

    byte = h % 256
    hi = int(byte / 16)
    lo = byte % 16
    return substr(NIBBLE, hi + 1, 1) substr(NIBBLE, lo + 1, 1)
}

mode == "format" {
    if (NR >= start_line && (max_lines == 0 || NR - start_line + 1 <= max_lines)) {
        printf "%d#%s:%s\n", NR, hash_line($0, NR), $0
    }
    next
}

mode == "validate" || mode == "context" {
    file_lines[NR] = $0
    file_len = NR
    next
}

END {
    if (mode == "validate") {
        for (ln in anchor_hash) {
            actual = hash_line(file_lines[ln], ln)
            if (actual == anchor_hash[ln]) {
                print "OK " ln " " actual
            } else {
                print "MISMATCH " ln " " anchor_hash[ln] " " actual
                mismatch_found = 1
            }
        }
        if (mismatch_found) exit 1
    }

    if (mode == "context") {
        for (ln in anchor_hash) {
            actual = hash_line(file_lines[ln], ln)
            if (actual != anchor_hash[ln]) {
                mismatch_found = 1
                ctx_start = ln - 2
                if (ctx_start < 1) ctx_start = 1
                ctx_end = ln + 2
                if (ctx_end > file_len) ctx_end = file_len
                printf "MISMATCH at line %d: expected %s, got %s\n", ln, anchor_hash[ln], actual
                for (k = ctx_start; k <= ctx_end; k++) {
                    h = hash_line(file_lines[k], k)
                    if (k == ln) {
                        printf ">>> %d#%s:%s\n", k, h, file_lines[k]
                    } else {
                        printf "    %d#%s:%s\n", k, h, file_lines[k]
                    }
                }
                print ""
            }
        }
        if (mismatch_found) exit 1
    }
}
