# tailscale plugin

Runs the harness web UI as a dedicated tailnet node — a second,
unprivileged `tailscaled` in userspace-networking mode (own socket +
state, no TUN, no root), separate from the machine's main node. Inbound
traffic arrives via `tailscale serve`, which terminates TLS in-process.

## Requirements

`tailscale` + `tailscaled` on PATH (all subcommands check and error with
an install hint otherwise). Unit files are embedded templates generated
at `hs tsnet install` time with absolute paths resolved on the host —
nothing else is machine-specific.

## Setup

    hs auth set tailscale        # paste an auth key (or export TS_AUTHKEY)
    hs tsnet up                  # start node + serve web UI on it
    hs tsnet url                 # https://harness-web.<tailnet>.ts.net/

## Boot persistence

    hs tsnet install             # two systemd user units:
                                 #   harness-tsnet.service  (tailscaled)
                                 #   harness-web.service    (hs serve)
    hs tsnet uninstall

The web unit runs with cwd `~/.harness/workspace` — a neutral
directory so agents spawned from the UI aren't tied to a project.

The serve config persists in the node's state file, so the units only
need to start the daemon and web server.

## Env

- `TSNET_HOSTNAME` — tailnet node name (default `<hostname>-web`, e.g. `wayreth-web`)
- `TSNET_BACKEND` (default `127.0.0.1:8080`)
- `TS_AUTHKEY` — auth key for `hs auth set tailscale`

State: `~/.harness/tsnet/` (tailscaled.state, logs). The auth key is
stored via the standard auth plugin in `~/.harness/.auth.json`.

## Notes

- Userspace networking means the node has no OS-level `tailscale1`
  interface; only `serve`/`funnel` (and the built-in SOCKS5/HTTP proxy
  at `127.0.0.1:1055`, `tsc debug prefs`) can carry traffic. That is
  fine for a web server.
- First `up` consumes the auth key; afterwards the node reuses its
  stored identity until the key/node expires in the admin console.