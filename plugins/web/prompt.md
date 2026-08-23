# talking to open web sessions

If a human has your session open in a browser tab (or several), you can
push elements straight into their page. Each open tab has a fifo:

    $HARNESS_SESSION/.ui/*.fifo     # one per live SSE connection

Write **one HTML fragment per line** to every fifo to fan out. The web UI
wraps each line in a datastar patch; elements with an id that already
exists on the page morph in place, new elements are appended to `<body>`.

## toast

    frag='<div id="toast" style="position:fixed;top:1rem;right:1rem;background:#222;color:#fff;padding:.6rem 1rem;border-radius:6px;z-index:99">working on it…</div>'
    for f in "$HARNESS_SESSION"/.ui/*.fifo; do printf '%s\n' "$frag" > "$f"; done

Reuse `id="toast"` to update it, or remove it with a self-clearing variant:

    '<div id="toast" data-on-interval(3s)="this.remove()"></div>'

## status line

    '<div id="status" style="position:fixed;bottom:5.5rem;left:1rem;color:#888">step 3/7: running tests</div>'

## anything

The fragment is arbitrary HTML; data-* attributes you include are live
(datastar executes them). Keep fragments single-line (one write per fifo
per event). No fifo directory means nobody is watching — write nothing
and move on; writes to a missing fifo just error, and stale fifos (dead
handlers) are swept after 30 minutes, so guard with a quick `ls`.

## notes

- The user's transcript also re-renders automatically whenever any file
  in the session dir changes — you do not need the fifo for that.
- Push sparingly: this lands directly in front of a human.