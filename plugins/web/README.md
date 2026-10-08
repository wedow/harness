# Web frontend

`harness serve [port]` serves the one continuous chat on
`http://127.0.0.1:8080`. It requires `socat` and runs independently of the
reactor and workers. Closing a browser or restarting the HTTP server does
not stop an agent task.

The browser polls committed messages every 1.5 seconds. It reconnects
automatically, preserves the draft, and retries unacknowledged submissions
with the same message ID so a lost response cannot duplicate a message.
Earlier history loads in pages. Replies appear whole when committed;
there is no token stream or session selector.

`lib/handler` handles one request per socat connection. `lib/http.sh`
frames responses with byte lengths and optional gzip. The standalone
HTML, JavaScript, and CSS live in `public/`; no build step is needed.

| Endpoint | Behavior |
| --- | --- |
| `GET /` | Chat page |
| `GET /api/events?after=N&limit=N` | Committed events after a cursor; cursor zero loads the newest page |
| `GET /api/events?before=N&limit=N` | Earlier history in chronological order |
| `GET /api/status` | Actor, request, job, and component activity |
| `POST /api/messages` | Save JSON `{text,id}`; repeated IDs deduplicate |
| `POST /api/cancel` | Request cancellation of the current main task |

Page sizes range from 1 to 200. Request bodies are limited to 1 MiB.
The frontend uses `HARNESS_DATA` through the shared store and never opens
the old session directory.

## Reverse proxies

The listener stays on loopback. Requests require a loopback Host or an
explicitly allowed proxy Host. Browser POSTs require a matching local
Origin or an explicitly trusted public Origin:

```bash
export HARNESS_WEB_ALLOWED_ORIGINS='https://agent.example-tailnet.ts.net'
harness serve
```

An allowed Origin also permits its hostname as Host, including proxies
that rewrite Host to loopback. Additional exact Hosts can be configured
with `HARNESS_WEB_ALLOWED_HOSTS=proxy.internal:8080`. Both variables accept
comma- or space-separated entries. Origins include the scheme and port;
Hosts include any port. Wildcards are not supported. Restart the HTTP
server after changing these settings.

For settings that survive a plain start, create `$HARNESS_HOME/web.conf`
(`~/.harness/web.conf` by default):

```ini
allowed_origins=https://agent.example-tailnet.ts.net
```

`allowed_hosts` accepts the same exact Host list as the environment setting.
Environment variables override their corresponding saved setting, including an
explicitly empty value. The file contains literal `key=value` lines and is never
executed. Saved settings reload on each request, so editing the file needs no
web restart.

For [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve),
run `tailscale serve status` to find the HTTPS URL, then save that exact origin
under `allowed_origins`. `tailscale serve 8080` alone does not configure the
Harness allowlist. A `forbidden host` response means the request reached Harness
but its hostname has not been allowed.
