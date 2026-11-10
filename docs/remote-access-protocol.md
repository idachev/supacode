# Supacode remote access — wire protocol v1

This protocol specification is licensed under the MIT License (see `remote-relay/LICENSE`), so other
clients and hosts may implement it. The Supacode app code that implements the host stays under the
repository's root LICENSE.

Three parts speak this protocol: the Android app (client), the Cloudflare relay
(`supacode-relay`, Worker + Durable Object) and Supacode on the Mac (host).

## Transport

- Relay base URL: the deployed Worker, `https://<worker>.<subdomain>.workers.dev` (see
  `docs/remote-access.md`).
- Client: WebSocket `wss://…/client`, header `Authorization: Bearer <CLIENT_KEY>`. Optional query
  `host=<hostId>` (see "Multiple hosts").
- Host: WebSocket `wss://…/host`, header `Authorization: Bearer <HOST_KEY>`. Optional query
  `id=<hostId>` and `name=<host name>` (see "Multiple hosts").
- A bad or missing key gets HTTP 401 before the upgrade. A `host` or `id` value that is not a valid
  host id gets HTTP 400 `bad host id`. Any other path gets 404.
- All frames are **text** frames carrying UTF-8 JSON, except the keepalive.
- Keepalive: either end sends the bare text `ping` every 30 s; the relay answers `pong`
  itself (auto-response). Ignore `pong`.
- Binary payloads (terminal bytes) travel as base64 in a `b64` field.

## Relay framing

The relay gives every client WebSocket a `connId` (random 16 hex chars). Every client socket is
bound to at most one host (see "Multiple hosts"); all rules below are per host.

- client → relay: a plain JSON message. The relay forwards it to its bound host as
  `<connId>\n<json>`.
- host → relay: `<connId>\n<json>`. The relay strips the prefix and sends `<json>` to that
  client, but only when that `connId` is bound to the sending host; otherwise the frame is dropped.
  An unknown `connId` is dropped. The special `connId` `*` broadcasts to all clients bound to the
  sending host. The special `connId` `@` is a control frame for the relay and is never forwarded
  (see "Multiple hosts").
- relay → host, on client connect / close: `<connId>\n{"t":"conn.open","sameNetwork":true|false}` and
  `<connId>\n{"t":"conn.close"}`. They go only to the host the client is bound to, and
  `conn.close` only when that host is online. `sameNetwork` is a hint: the phone's and that host's
  public IPs are equal (IPv4) or share a /64 (IPv6). When a host (re)connects, the relay sends a
  `conn.open` for every client bound to it.
- relay → client: `{"t":"relay","hostOnline":true|false,…}` right after the client connects,
  whenever its bound host connects or disconnects, and whenever the host list changes. The extra
  fields `host` and `hosts` are described in "Multiple hosts".
- A client message while its bound host is offline (or when it has none) is dropped; the relay
  answers the client `{"t":"error","id":<id if any>,"message":"host offline"}`.
- A new host connection closes the old one only when both use the same host id (code 4000,
  "replaced"). Hosts with different ids stay connected side by side.

## Multiple hosts

Several Macs (hosts) can be online on one relay at the same time, with the same `HOST_KEY` and
`CLIENT_KEY`. A client talks to one host at a time.

### Host id and name

- `hostId` is the stable identity of one Mac on the relay. Supacode derives it: the first 16
  lowercase hex characters of `SHA-256("supacode-remote-host-v1:" + <hardware UUID>)`. It is never
  shown to the user. A host may use any id that matches `^[A-Za-z0-9_-]{1,64}$`.
- The host name is what clients show for a Mac. It may change at any time. Supacode sends the
  `hostName` it is configured with, or the computer name when none is set.
- Normalization (done by the host and again by the relay; the relay's result is authoritative):
  control characters become spaces, surrounding whitespace is trimmed, the result is cut to 64
  Unicode scalars. An empty result means "no name" and the name is omitted.

### URL parameters

- Host: `wss://<relay>/host?id=<hostId>&name=<percent-encoded host name>`. Both are optional. The
  relay never rejects a `name`; it normalizes and cuts it.
- Client: `wss://<relay>/client?host=<hostId>`. The socket is bound to that host for its whole life.
  To switch hosts, close the socket and open a new one with another `host`. An unknown but valid
  `host` binds anyway; the host is then offline.
- A `/host?id=` or `/client?host=` value that does not match `^[A-Za-z0-9_-]{1,64}$` gets HTTP 400
  `bad host id`, after the key check and before the upgrade. A 400 does not count as a failed key.
- A missing parameter is valid. `/host` without `id` is a legacy host: the relay files it as host id
  `default`, with no name. `/client` without `host` is an unbound client: it is bound to no host.

### Same host id replaces, other ids do not

A new host connection with the same `hostId` closes the old one (code 4000, "replaced", after a
`replaced` text notice). A host with another id is never touched. Two Supacode copies on one Mac
derive the same id and replace each other. The `hostOnline` false → true edge after a replacement
goes only to clients bound to that host id.

### Relay message

```json
{"t":"relay","hostOnline":true,"host":"3f9a0c1d2e4b5a69",
 "hosts":[{"id":"3f9a0c1d2e4b5a69","name":"Office Mac","online":true},
          {"id":"a41b7c93d05e8f26","name":"Laptop","online":false}]}
```

- `hostOnline`: whether the bound host is online. Without a bound host it is `false`.
- `host`: the bound host id. Omitted for an unbound client.
- `hosts`: every host the relay knows, online or not, sorted by name (case-insensitive, unnamed
  last), then by id. `name` is omitted when unknown.
- Sent right after the client connects; whenever the bound host goes online or offline (including
  the false → true edge of a replacement); whenever the list changes (a host connects, disconnects,
  is renamed or is pruned). Each client gets its own copy, with its own `host` and `hostOnline`.
- A client acts on `hostOnline` edges only (send `hello` on false → true). A repeated
  `hostOnline:true` carries a list update and nothing else.
- An unbound client gets the list and every list update, but no `conn.open`; any message from it
  gets the `host offline` error. It is meant for reading the list before the client picks a host.
- The relay remembers hosts across restarts. An offline host not seen for 30 days is dropped from
  `hosts`, and at most 20 offline hosts are kept (the oldest go first). Online hosts are always
  listed. The legacy host `default` is listed only while it is online.
- Choosing a host (client). A saved selection never changes by itself; only the owner's pick
  changes it. With nothing saved, connect without `host`, read `hosts`, and select the host when
  exactly one is online; otherwise show the list. When `hosts` is present but does not list the saved
  id, keep the selection, show the host as offline and show the list. With a missing `hosts` (old
  relay) keep the saved selection too.
- A relay without multi-host support sends `relay` without `hosts` and ignores `id`, `name` and
  `host`. A client treats a missing `hosts` as "single host": no list, no `host` query. An empty
  `hosts` array is different: a new relay that knows no host yet.

### Rename: host.name

host → relay, on the reserved `connId` `@`: `@\n{"t":"host.name","name":"<new name>"}`.

- The relay normalizes the name, updates the host, and sends the new list to every client. A frame
  without `name` (or whose name normalizes to empty) clears the name: the host is then listed
  without a name. No
  reconnect: the clients of that host keep their streams.
- `host.name` is the only control frame. The relay drops any other `@` frame, and never forwards `@`
  to a client. Connection ids are 16 hex characters, so `@` never collides with one. An old relay
  drops the frame too.

### Version rules

All of the above is additive and optional, so `v` stays `1` and this document stays "wire protocol
v1". `v` changes only when an existing field changes meaning, or when a message that the other side
must understand is added. New optional fields and new relay-only frames do not change it. The LAN
MAC input `supacode-lan-fp-v1:` is unchanged.

Mixed versions (not confirmed on a live relay): a new host or client against an old relay works as a
single host. A new relay with an old Supacode shows that host as `default`, with no name. A client
that does not send `host` is unbound and sees every host offline, so it must be updated together
with the relay.

## Application messages (client ⇄ host)

Every request may carry a numeric `id`; the response repeats it.

### hello

- client → host `{"t":"hello","v":1}`
- host → client `{"t":"hello","v":1,"host":"<host name>","hostId":"<hostId>","lan":{"addrs":["192.168.1.10"],"port":49731,"fp":"<hex>","fpMac":"<hex>"}}`
- `host` is the configured host name, or the Mac's computer name when none is set. `hostId` is
  omitted when the host has none (a legacy host). A client that selected a host ignores `lan` when
  `hostId` is present and differs from that host (see "LAN shortcut").
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

### resize

- client → host `{"t":"resize","contentId":"<content uuid>","cols":N,"rows":M}` — sets one
  terminal's grid on demand (a button on the client, never sent automatically).
- Only for the content this connection is attached to; for any other content it is ignored.
- `cols` and `rows` are integers within the 64-bit range; the host clamps them to 20…500 columns and 5…200 rows. A
  missing `cols` or `rows`, or one that is not an integer, makes the host ignore the request
  (it logs it).
- Replies (a valid request for the attached content gets one of these). Every `size` is the size
  the session's PTY really has (what the `out` stream renders at), read after the change:
  - The PTY takes the size (within about 3 s): the requesting client gets
    `{"t":"size","contentId":"…","cols":…,"rows":…}` with that size, even when it already had it;
    every other client attached to that content gets it when its size changes.
  - The grid already has that size: the same `size`, at once.
  - The terminal has no live surface on the Mac (its tab was hidden long enough to hibernate, or
    has not been shown since Supacode started; `attach` still works then): the host starts it in
    the background, off screen, and applies the size once the terminal is ready, within about
    6 s; then `size` as above. The Mac does not switch to the tab.
  - The PTY keeps another size: a `size` with the size it has, then an `error` as below. A later
    change of the PTY still arrives as the usual `size`.
  - The host cannot apply it (the tab is gone, the terminal did not start, it was not ready in
    time, or the PTY size cannot be read): the requesting client gets
    `{"t":"error","id":null,"message":"…","code":"resize_failed","contentId":"…"}`
    (`id` echoes the request's `id` when it had one; `message` is a short English reason).
  - A newer `resize` from the same client, a `detach` or an `attach` of another content cancels a
    pending one; the cancelled request gets no reply.
- The requested size holds until the Mac's own pane for that tab changes layout (a window
  resize, the pane shown or hidden, a split change, zoom); then the pane's size returns and
  the clients get `size`. A later `resize` from any client wins again (last request wins).
- Old hosts answer an unknown `t` with an `error` and send no `size`; the resize simply has no
  effect. Hosts before `resize_failed` send nothing when a resize cannot be applied, and nothing
  for a resize to the current size.

### tab.new

- client → host `{"t":"tab.new","id":4,"worktreeId":"<worktree id>"}`, or with a start size
  `{"t":"tab.new","id":4,"worktreeId":"…","cols":N,"rows":M}`. `cols` and `rows` are optional
  integers, sent together.
- host → client `{"t":"tab.new","id":4,"worktreeId":"…","tabId":"<tab uuid>","contentId":"<content uuid>"}`
  once the new terminal tab exists and its content can be attached.
- The Mac opens one new terminal tab (the default shell, the worktree's directory) in that
  worktree, as its "new tab" action does. It does not change which worktree the Mac window shows.
- With `cols` and `rows`, the new terminal starts at that size, clamped by the host to
  20…500 columns and 5…200 rows. Without them, or when one is missing or is not an integer,
  it starts at most 120 × 40, not at the size of the whole Mac window. The start size holds
  while the Mac does not show the tab; once the Mac shows it, the terminal takes its pane's
  size and the client gets a `size` message. An existing tab is resized with `resize`.
- Old hosts ignore `cols` and `rows` (no version change); the reply is the same either way.
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
- Optional fields, omitted when absent: `code`, a machine-readable reason (today only
  `resize_failed`), and `contentId`, the terminal the error is about (for requests without an `id`).
  Clients must ignore codes they do not know and fall back to `message`.

## LAN shortcut

When both ends are on one network, the phone may talk to the Mac directly and skip the relay. The
LAN link is standard TLS 1.3 with a self-signed certificate that the phone pins.

### Trust

- Supacode creates a self-signed certificate (RSA 2048, 10 years) on first use and keeps it as
  `remote-lan/identity.p12` (mode 0600) in its config directory.
- The phone gets the certificate's fingerprint `fp` in `hello` through the relay. The relay could
  rewrite that message, so the phone first checks `fpMac` (see `hello`): only someone who knows the
  client key can produce it, and the relay only knows the key's hash. A wrong `fpMac` means no LAN
  attempt. Every host has its own certificate and `fp`; the client takes `fp` from the `hello` of
  the host it is bound to, and keeps none across connections. It makes no LAN attempt when the
  `hello` carries a `hostId` that differs from the selected host. `fpMac` uses the shared client
  key, so it proves "made by someone with the client key", not "made by this Mac".

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
When the client switches to another host, it closes the LAN socket together with the relay socket.
