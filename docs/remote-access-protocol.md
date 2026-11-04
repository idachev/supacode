# Supacode remote access — wire protocol v1

This protocol specification is licensed under the MIT License (see `remote-relay/LICENSE`), so other
clients and hosts may implement it. The Supacode app code that implements the host stays under the
repository's root LICENSE.

Three parts speak this protocol: the Android app (client), the Cloudflare relay
(`supacode-relay`, Worker + Durable Object) and Supacode on the Mac (host).

## Transport

- Relay base URL: the deployed Worker, `https://<worker>.<subdomain>.workers.dev` (see
  `docs/remote-access.md`).
- Client: WebSocket `wss://…/client`, header `Authorization: Bearer <CLIENT_KEY>`.
- Host: WebSocket `wss://…/host`, header `Authorization: Bearer <HOST_KEY>`.
- A bad or missing key gets HTTP 401 before the upgrade. Any other path gets 404.
- All frames are **text** frames carrying UTF-8 JSON, except the keepalive.
- Keepalive: either end sends the bare text `ping` every 30 s; the relay answers `pong`
  itself (auto-response). Ignore `pong`.
- Binary payloads (terminal bytes) travel as base64 in a `b64` field.

## Relay framing

The relay gives every client WebSocket a `connId` (random 16 hex chars).

- client → relay: a plain JSON message. The relay forwards it to the host as
  `<connId>\n<json>`.
- host → relay: `<connId>\n<json>`. The relay strips the prefix and sends `<json>` to that
  client. An unknown `connId` is dropped. The special `connId` `*` broadcasts to all clients.
- relay → host, on client connect / close: `<connId>\n{"t":"conn.open","sameNetwork":true|false}` and
  `<connId>\n{"t":"conn.close"}`. `sameNetwork` is a hint: the phone's and the host's public IPs are
  equal (IPv4) or share a /64 (IPv6). When the host (re)connects, the relay sends a
  `conn.open` for every client already connected.
- relay → client: `{"t":"relay","hostOnline":true|false}` right after the client connects,
  and again whenever the host connects or disconnects.
- A client message while the host is offline is dropped; the relay answers the client
  `{"t":"error","id":<id if any>,"message":"host offline"}`.
- A new host connection closes the old one (code 4000, "replaced").

## Application messages (client ⇄ host)

Every request may carry a numeric `id`; the response repeats it.

### hello

- client → host `{"t":"hello","v":1}`
- host → client `{"t":"hello","v":1,"host":"<Mac computer name>","lan":{"addrs":["192.168.1.10"],"port":49731,"fp":"<hex>","fpMac":"<hex>"}}`
- `lan` is present only when the relay said `sameNetwork` for this phone and the Mac's LAN
  endpoint runs (see "LAN shortcut"). `addrs` are the IPv4 addresses of the Mac's active `en*`
  interfaces (Wi-Fi/Ethernet), without link-local 169.254/16 and loopback; any range, not only
  RFC 1918. `fp` is the lowercase hex SHA-256 of the LAN certificate's
  DER bytes; `fpMac` is the lowercase hex HMAC-SHA256 with key = UTF-8 bytes of the client key over
  the UTF-8 text `supacode-lan-fp-v1:` + `fp`.
- The Mac may answer `hello` up to 3 s late while its LAN endpoint is still starting (just after
  the app launched), so that a `sameNetwork` phone gets `lan` in that answer. If the endpoint is not
  ready by then, the answer goes without `lan`. Other phones get the answer at once.

### list

- client → host `{"t":"list","id":1}`
- host → client:

```json
{"t":"list","id":1,"repos":[
  {"id":"<repository id>","name":"supacode","group":"<sidebar group name, omitted when none>","worktrees":[
    {"id":"<worktree id>","name":"remote-access","branch":"remote-access",
     "status":"main|pinned|unpinned","focused":true,"title":"<custom title or null>",
     "working":true,"tabs":[
       {"id":"<tab uuid>","contentId":"<content uuid>","title":"claude","focused":true,
        "working":false,"readOnly":false,
        "agents":[{"agent":"claude","activity":"busy|awaitingInput|idle|error|compacting"}]}
     ]}
  ]}
]}
```

`sections` mirrors the Supacode sidebar in display order (the fork shows Active above Pinned):

```json
"sections":[
  {"kind":"active","title":"Active","worktreeIds":["<worktree id>", "…"]},
  {"kind":"pinned","title":"Pinned","worktreeIds":["…"]},
  {"kind":"group","title":"Work","collapsed":true,"repositoryIds":["<repository id>"]},
  {"kind":"repository","repositoryId":"<repository id>"}
]
```

- `active` / `pinned` list worktree rows from any repository (look them up in `repos`).
- `group` is a repository-group header; its `repositoryIds` follow it. `collapsed` is the
  sidebar's state and only a hint for the phone's initial state.
- `repository` is an ungrouped repository.
- Each repository has `rowIds`: the worktree ids the sidebar shows under it, in order, without the
  rows hoisted into Active / Pinned. A repository section renders these rows.

Optional fields (`group`, `title`, `collapsed`, …) are omitted when they have no value. Archived worktrees are left out. Order follows the sidebar: per repository main first, then
pinned, then the rest. `contentId` is the id the terminal messages use. `agent` is the raw
value of the app's agent enum (`claude`, `codex`, …); `activity` is the raw activity value.

### attach / detach

- client → host `{"t":"attach","id":2,"contentId":"…","scrollback":500}`
- host → client `{"t":"attached","id":2,"contentId":"…","cols":180,"rows":50}`
- then host → client `{"t":"out","contentId":"…","b64":"…"}` — the first `out` is the
  current screen (VT, with up to `scrollback` rows of history above it); the next ones are
  live PTY output in order. When the session does not return its screen within about 3 s
  (a just-started tab), the first `out` is the output seen so far instead, and live output
  follows as usual.
- host → client `{"t":"size","contentId":"…","cols":…,"rows":…}` when the Mac's grid changes.
- host → client `{"t":"detached","contentId":"…","reason":"…"}` when the session ends or
  the stream fails.
- client → host `{"t":"detach","contentId":"…"}` stops the stream. Closing the client
  WebSocket detaches everything it had.
- A client may attach one content at a time; attaching another detaches the first.

### input

- client → host `{"t":"input","contentId":"…","b64":"…"}` — raw bytes written to the PTY
  (Enter is `\r`, Esc `\u001b`, Ctrl+C `\u0003`, arrows `\u001b[A` … `\u001b[D`).
  Input never resizes the session and never makes the phone the zmx leader.

### tab.new

- client → host `{"t":"tab.new","id":4,"worktreeId":"<worktree id>"}`
- host → client `{"t":"tab.new","id":4,"worktreeId":"…","tabId":"<tab uuid>","contentId":"<content uuid>"}`
  once the new terminal tab exists and its content can be attached.
- The Mac opens one new terminal tab (the default shell, the worktree's directory) in that
  worktree, as its "new tab" action does. It does not change which worktree the Mac window shows.
- An unknown or archived worktree, or a tab that does not start within 10 s, gives
  `{"t":"error","id":4,"message":"…"}`.
- The phone attaches to `contentId` itself. There is no `tab.close`: the user ends the shell
  (`exit`) to close a tab.

### suggest

- client → host `{"t":"suggest","id":3,"contentId":"…"}`
- host → client `{"t":"suggest","id":3,"contentId":"…","suggestions":["…","…"]}`
- Suggestions are plain strings without a trailing newline. The client only puts one in the
  input field; it never sends it on its own.

### errors

- host → client `{"t":"error","id":<request id or null>,"message":"…"}`.

## LAN shortcut

When both ends are on one network, the phone may talk to the Mac directly and skip the relay. The
LAN link is standard TLS 1.3 with a self-signed certificate that the phone pins.

### Trust

- Supacode creates a self-signed certificate (RSA 2048, 10 years) on first use and keeps it as
  `remote-lan/identity.p12` (mode 0600) in its config directory.
- The phone gets the certificate's fingerprint `fp` in `hello` through the relay. The relay could
  rewrite that message, so the phone first checks `fpMac` (see `hello`): only someone who knows the
  client key can produce it, and the relay only knows the key's hash. A wrong `fpMac` means no LAN
  attempt.

### Endpoint

- `wss://<addr>:<port>/lan` for each address in `lan.addrs` (IPv4).
- TLS 1.3 only. The client accepts the server ONLY when the SHA-256 of the leaf certificate's DER
  bytes equals `fp`; host name checks are skipped. A wrong certificate fails the handshake before
  any request header is sent.
- Header `Authorization: Bearer <CLIENT_KEY>`; a wrong key is refused at the upgrade and the Mac
  closes the connection. An accepted upgrade carries the response header `X-Supacode-LAN: 1`; clients
  may ignore it.
- After the upgrade the application messages are the same as above, as text frames, with no relay
  framing and no `relay` status messages (the Mac is online by definition). Text `ping` is
  answered with `pong`.
- Supacode accepts any source address. The protection is the pinned TLS certificate, the client
  key, at most 8 LAN peers at a time, and a 10 second limit: a connection that has not finished
  TLS and the upgrade by then is dropped.

### Client behaviour

Try the addresses with a short connect timeout (about 2.5 s). On success send `hello`, `list` and
the open `attach` over the LAN socket and keep the relay socket open as an idle fallback (ping
only). When the LAN socket closes, go back to the relay and re-attach. Try the LAN again whenever a
`hello` reply carries `lan`.
