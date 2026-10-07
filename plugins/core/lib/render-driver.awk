# render-driver.awk — main rules for lib/render-result: slurp stdin, render
# a flat JSON object as YAML, pass anything else through unchanged.
# Requires yaml.awk loaded first (render-result passes both via -f).
{ buf = buf $0 "\n" }
END {
  sub(/\n$/, "", buf)
  y = json2yaml(buf)
  print(y == "" ? buf : y)
}