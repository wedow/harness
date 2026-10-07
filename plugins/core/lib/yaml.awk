# yaml.awk — shared flat-JSON→YAML rendering (POSIX awk).
# json2yaml(j) renders a flat JSON object of scalar values as YAML:
# multi-line strings become block scalars, strings needing quoting stay
# JSON-escaped (valid YAML double-quoted). Non-flat, non-object, or
# malformed input returns "" — callers fall back to the raw text.
# As a side effect it fills vm[key] with unescaped string values; callers
# use this for summary labels (reset with split("", vm)).
# Included via -f by plugins/core/lib/render-driver.awk (tool result
# bodies) and the web transcript renderer (tool_call inputs).

function junes(s, t) {
  t = s
  gsub(/\\\\/, "\x01", t)
  gsub(/\\n/, "\n", t); gsub(/\\t/, "\t", t)
  gsub(/\\"/, "\"", t); gsub(/\\\//, "/", t)
  gsub(/\x01/, "\\", t)
  return t
}

function jquote(s, p, c) { # s starts at the opening quote; returns index of its close
  p = 2
  while (p <= length(s)) {
    c = substr(s, p, 1)
    if (c == "\\") p += 2
    else if (c == "\"") return p
    else p++
  }
  return 0
}

function yscalar(v, out, i, n, L) { # v = raw JSON string source, quotes stripped
  if (index(v, "\\n") == 0) {
    if (v != "" && v !~ /[\\"]|#/ && v !~ /^[ \t]/ && v !~ /[ \t]$/)
      return junes(v)
    return "\"" v "\""   # JSON escaping is valid YAML double-quoted
  }
  v = junes(v); sub(/\n$/, "", v)
  n = split(v, L, "\n"); out = "|"
  for (i = 1; i <= n; i++) out = out "\n  " L[i]
  return out
}

function json2yaml(j, rest, key, p, c, v, out) {
  if (j !~ /^[ \t\n\r]*\{/) return ""
  rest = j
  sub(/^[ \t\n\r]*\{/, "", rest); sub(/\}[ \t\n\r]*$/, "", rest)
  while (rest != "") {
    sub(/^[ \t\n\r]+/, "", rest)
    if (rest == "") break
    if (substr(rest, 1, 1) == ",") { rest = substr(rest, 2); continue }
    if (substr(rest, 1, 1) != "\"") return ""
    p = jquote(rest); if (!p) return ""
    key = substr(rest, 2, p - 2)
    rest = substr(rest, p + 1)
    sub(/^[ \t\n\r]*:/, "", rest)
    sub(/^[ \t\n\r]+/, "", rest)
    c = substr(rest, 1, 1)
    if (c == "\"") {
      p = jquote(rest); if (!p) return ""
      v = substr(rest, 2, p - 2); rest = substr(rest, p + 1)
      out = out key ": " yscalar(v) "\n"
      vm[key] = junes(v)
    } else if (c == "[" || c == "{") {
      return ""   # not flat: caller shows raw JSON
    } else {
      match(rest, /^[^,}]*/)
      out = out key ": " substr(rest, 1, RLENGTH) "\n"
      rest = substr(rest, RLENGTH + 1)
    }
  }
  return out
}