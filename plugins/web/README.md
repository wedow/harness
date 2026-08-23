# web plugin

Server-rendered web UI for harness sessions over socat. No build step, no
node; the only asset is the vendored `public/datastar.js` (v1.0.2).

    serve              entry point; requires socat, binds 127.0.0.1:$PORT (default 8080)
    lib/handler        per-connection HTTP entry; stdin/stdout is the socket
    lib/http.sh        HTTP/SSE primitives, html escaping
    lib/pages.sh       routes, layout, transcript renderer, SSE hub

## Model

- socat forks one `handler` bash process per connection.
- Routing (after query-string strip): `GET /`, `GET /datastar.js`,
  `GET /s/<id>`, `GET /s/<id>/events`, `POST /new`, `POST /s/<id>`.
- Pages are fully server-rendered. Datastar (loaded as a module from
  `/datastar.js`) only morphs fragments we push over SSE and runs small
  attribute expressions (`data-init`, `data-on:*`).
- `POST /new` with an empty message creates a session without launching an
  agent (the sidebar `+` button). With a message it creates and runs.
- Agents are launched backgrounded under a per-session `flock`
  (`$SESSION/.lock`), one in-flight turn per session, entirely independent
  of HTTP connections. The UI is an agent multiplexer.

## SSE hub (`GET /s/<id>/events`)

Each connection is a long-lived handler process that pushes:

1. **Transcript re-render** — any file change under `$SESSION` (mtime/size
   fingerprint via `_dir_sig`) triggers a full `<div id="transcript">`
   fragment. Datastar morphs it in place by id.
2. **Live UI reload** — changes to this plugin's own files push a hidden
   `<div id="uireload" data-init="location.reload()">`; every open tab
   hard-reloads and picks up new markup/CSS. Editing the plugin is hot.
3. **Heartbeat** — every ~15s a hidden `<div id="hb" data-t="...">` morph.
   The client watchdog reloads if beats stop for 45s (server death etc).
4. **Agent channel** — lines written to `$SESSION/.ui/*.fifo` are wrapped
   as append-mode patch events. One fifo per connection, created on
   connect, removed on disconnect. See `prompt.md`.

The client fetch uses `{retry: 'always', retryMaxCount: 99999,
openWhenHidden: true}` so clean server EOFs and idle tabs reconnect on
their own; each (re)connect sends an immediate full render, so reconnect
means resync.

## Layout

- Collapsible session sidebar (hamburger on mobile <900px, pinned on
  desktop) with new-session form and recent sessions; current highlighted.
- Transcript scrolls in its own viewport-height container; the reply form
  is sticky at the bottom.
- Autoscroll only while the user is at the bottom (sticky-flag logic);
  a floating ↓ button appears when scrolled up.
- Draft persistence: the reply input syncs to
  `localStorage["draft:<path>"]`, restored on load (with focus), cleared
  on submit. Reloads — including live-UI reloads mid-typing — are near
  seamless.

## Gotchas learned the hard way

- socat execs children with SIGPIPE ignored; an ignored signal cannot be
  re-trapped in bash, so dead-socket detection is via printf's nonzero
  return on EPIPE (`sse_patch ... || exit 0`).
- Datastar's default outer mode only patches ids that already exist;
  brand-new elements need `selector body` + `mode append` (`sse_patch
  <frag> append`).
- Datastar `retry` defaults to `'auto'`, which never retries a clean
  stream EOF — only network errors. Use `retry: 'always'`.
- Everything runs over localhost; fragments are full re-renders and that
  is fine.