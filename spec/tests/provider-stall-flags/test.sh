#!/usr/bin/env bash
# reg-03 + tq-01: per-curl placement of the stall-detection flags.
#
# --speed-limit 1 --speed-time N aborts a transfer that goes silent for N
# seconds. That is correct for STREAMING curls (live SSE emits pings/
# keepalives, so the flag catches genuine stalls without false-tripping) but
# WRONG for NON-STREAMING curls, where the server sends zero bytes while it
# computes the full response — the flag falsely aborts any request whose
# server-side compute exceeds N (extended thinking, a slow local llama.cpp/
# vLLM endpoint) with curl rc=28 "Operation too slow".
#
# This structural test pins the placement for every provider, so removal or
# mis-placement of the flag on any future edit is caught in <1s with no
# network:
#   - anthropic/openai STREAMING curl (marked by -N): MUST carry --speed-time.
#   - anthropic/openai non-streaming curl (no -N): must NOT carry --speed-time.
#   - chatgpt STREAMING curl (-N) and buffered-SSE curl (no -N, but the
#     Responses API streams SSE — `stream: true` is hardcoded in the request —
#     so keepalives apply): MUST carry --speed-time.
#   - chatgpt token-refresh curl (auth.openai.com, buffered POST): must NOT
#     carry --speed-time.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

anthropic="${HARNESS_ROOT}/plugins/anthropic/providers/anthropic"
openai="${HARNESS_ROOT}/plugins/openai/providers/openai"
chatgpt="${HARNESS_ROOT}/plugins/chatgpt/providers/chatgpt"

# extract_curl_blocks FILE — print each `curl -sS ...` invocation as a block,
# from the line containing `curl -sS` through the matching close paren of the
# enclosing command/process substitution. Blocks are separated by \f. Tracks
# paren depth so the match is reliable across multi-line substitutions and
# inline closes (e.g. chatgpt's `--max-time 30)" || { ... }`).
extract_curl_blocks() {
  awk '
    BEGIN { depth = 0; in_curl = 0; target = 0; buf = "" }
    {
      if (in_curl) buf = buf $0 "\n"
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "(") depth++
        else if (c == ")") {
          depth--
          if (in_curl && depth < target) {
            printf "%s\f", buf
            in_curl = 0
            buf = ""
          }
        }
      }
      if (!in_curl && index($0, "curl -sS") > 0) {
        in_curl = 1
        buf = $0 "\n"
        target = depth
      }
    }
  ' "$1"
}

# blocks_both FILE RE1 RE2 — number of curl blocks matching both RE1 and RE2.
blocks_both() {
  extract_curl_blocks "$1" \
    | awk -v RS='\f' -v a="$2" -v b="$3" '$0 ~ a && $0 ~ b {n++} END{print n+0}'
}

# blocks_has_no FILE RE1 RE2 — number of curl blocks matching RE1 but NOT RE2.
blocks_has_no() {
  extract_curl_blocks "$1" \
    | awk -v RS='\f' -v a="$2" -v b="$3" '$0 ~ a && $0 !~ b {n++} END{print n+0}'
}

# total_curls FILE — count of curl blocks in FILE.
total_curls() {
  extract_curl_blocks "$1" | awk -v RS='\f' 'NF{c++} END{print c+0}'
}

fail() { echo "FAIL: $*"; exit 1; }

# --- anthropic: 1 streaming (-N) + 1 non-streaming ---
[[ "$(total_curls "$anthropic")" -eq 2 ]] || fail "anthropic: expected 2 curl blocks, got $(total_curls "$anthropic")"
[[ "$(blocks_has_no "$anthropic" '-N' '--speed-time')" -eq 0 ]] \
  || fail "anthropic: streaming (-N) curl must carry --speed-time (tq-01 regression guard)"
[[ "$(blocks_has_no "$anthropic" '--speed-time' '-N')" -eq 0 ]] \
  || fail "anthropic: non-streaming curl must NOT carry --speed-time (reg-03)"

# --- openai: 1 streaming (-N) + 1 non-streaming ---
[[ "$(total_curls "$openai")" -eq 2 ]] || fail "openai: expected 2 curl blocks, got $(total_curls "$openai")"
[[ "$(blocks_has_no "$openai" '-N' '--speed-time')" -eq 0 ]] \
  || fail "openai: streaming (-N) curl must carry --speed-time (tq-01 regression guard)"
[[ "$(blocks_has_no "$openai" '--speed-time' '-N')" -eq 0 ]] \
  || fail "openai: non-streaming curl must NOT carry --speed-time (reg-03)"

# --- chatgpt: 1 token-refresh + 1 streaming (-N) + 1 buffered-SSE ---
[[ "$(total_curls "$chatgpt")" -eq 3 ]] || fail "chatgpt: expected 3 curl blocks, got $(total_curls "$chatgpt")"
# Token-refresh (auth.openai.com, buffered POST) must NOT carry the flag.
[[ "$(blocks_both "$chatgpt" 'auth.openai.com' '--speed-time')" -eq 0 ]] \
  || fail "chatgpt: token-refresh curl must NOT carry --speed-time (reg-03)"
# Every chatgpt.com API curl (streaming -N + buffered-SSE) MUST carry the flag.
[[ "$(blocks_has_no "$chatgpt" 'chatgpt.com' '--speed-time')" -eq 0 ]] \
  || fail "chatgpt: Responses API curl(s) must carry --speed-time (tq-01 regression guard)"

echo "OK: stall-detection flags correctly placed (streaming + buffered-SSE: flagged; non-streaming + token-refresh: unflagged)"
