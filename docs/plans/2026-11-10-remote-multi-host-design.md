# Remote access: one phone, several Macs — design

Date: 2026-11-10. Status: draft for review. Builds on
`docs/plans/done/2026-11-03-remote-access-android-design.md`; the wire protocol is
`docs/remote-access-protocol.md`, operations are `docs/remote-access.md`.

## Intent

Ivan runs Supacode on more than one Mac. One Android app ("Supacode Remote") should reach all of
them through the one Cloudflare relay (`remote-relay/`) and the one key pair it already has. Today
the relay has a single Durable Object `idFromName("default")` with a single host slot: a second
Mac that connects evicts the first one (`replaced`, close code 4000), and the evicted Supacode
stops for good.

## Owner decisions (fixed)

- **СЦ1.** Hosts are different Macs. Two Supacode instances on one Mac stay as today: only the
  installed app hosts (`RemoteAccessConfig.mayHost`), and a forced second copy still replaces the
  first one.
- **ТЛ1.** The phone has one active host at a time. A host list (name, online/offline) lets the
  owner pick and switch.
- **ИМ1.** The host name lives in `~/.config/supacode/remote-access.json` under the new optional key
  `hostName`; missing means the Mac's computer name. Supacode Settings → Remote Access gets an
  editable text field that writes the same key and keeps every other key. A change reaches the
  phone without an app restart.
- **КЛ1.** The same relay keys serve every host: one `HOST_KEY`, one `CLIENT_KEY`.

## Goals

1. Several Macs are online on the relay at the same time; none evicts another.
2. The phone sees every known Mac with its name and online state, picks one, and switches.
3. The phone remembers the last picked Mac.
4. Renaming a Mac in Settings shows on the phone within seconds, without dropping its terminals.
5. Old Supacode builds keep working against the new relay where that is cheap (СВ1). Old phone
   builds are not supported: the APK is only on the owner's phone and he updates it at once (ОТ2).

## Non-goals

- Watching or getting alerts from several Macs at once (see АН6; the design leaves room for it).
- Forgetting a Mac from the phone (offline Macs age out on the relay, see РЛ5).
- Per-Mac keys or per-Mac permissions. Anyone with `HOST_KEY` may still claim any host id, the same
  trust as today.
- Several Supacode hosts on one Mac (СЦ1).

## Glossary

- **hostId** — stable identity of one Mac on the relay (ИД1). Never shown to the user.
- **host name** — what the phone shows for a Mac (ИМ1). May change at any time.
- **bound host** — the one host a phone connection talks to. Every client socket is bound to
  exactly one hostId for routing.
- **unbound client** — a client socket that did not ask for a host (`/client` without `host`): it
  gets the host list and talks to no host (СВ2).
- **legacy host** — a Supacode build that connects without an id. The relay files it as hostId
  `default`.

## Decisions

Each decision has an ID that the implementation split and the review cite.

### Host identity

**ИД1. hostId is derived from the Mac's hardware UUID, not stored.**
`hostId` = the first 16 lowercase hex characters of
`SHA-256("supacode-remote-host-v1:" + IOPlatformUUID)`. `HardwareInfo.uuid`
(`supacode/Support/HardwareInfo.swift`) already reads the UUID for telemetry and licensing.

Why:
- The only way to set up a second Mac with one key pair is to copy `remote-access.json` (and
  `remote-client-key.txt` for the LAN shortcut) to it. A stored id would be copied with it, and two
  Macs would then evict each other exactly as today. A derived id survives the copy.
- `remote-relay/scripts/gen-keys.mjs` rewrites the file (line 73 keeps only `enabled`, `relayURL`,
  `hostKey`); a derived id cannot be lost by such a rewrite.
- A rename never touches it; Migration Assistant to a new Mac gives the new Mac a new id, so the
  old and the new Mac never collide.
- Two Supacode copies on one Mac derive the same id and replace each other, which is СЦ1.
- Hashing with a fixed prefix keeps the raw hardware UUID off the relay. 64 bits is far beyond what
  a handful of Macs needs.

Rejected:
- Random `hostId` generated on first use and stored in `remote-access.json` (the brief's example):
  copied with the file to the second Mac, dropped by `gen-keys.mjs`, written from the app into a
  file the app otherwise only edits from Settings.
- Random id in a separate file (`remote-host-id`): still copied when the owner copies the config
  folder or uses Migration Assistant.
- The computer name as id: changes on rename (ИМ1), and two Macs can share a name.
- The raw IOPlatformUUID: exposes a hardware identifier to the relay and its logs.

When `HardwareInfo.uuid` is nil (not expected on a real Mac), Supacode connects without an id, logs
a warning once, and the relay files it as the legacy host `default` (СВ1).

**ИД2. Id and name travel in the `/host` URL query.**
`wss://relay.example.com/host?id=<hostId>&name=<percent-encoded host name>`. The query is built
from the configured `relayURL` (which ends in `/host`) with `URLComponents`: any existing `id` and `name`
items are replaced, every other query item is kept.

Why: the relay knows the host's identity at accept time, before any frame, so replacement within
one hostId (РЛ2) happens in `acceptHost` with no "socket without identity yet" state, and the
socket's attachment carries the id from accept on. The old Worker ignores
unknown query parameters, so a new Supacode works against an old relay (it just stays the single
host).

Rejected: a first frame `{"t":"host.hello","id":…}` from the host. It needs a pending state in the
Durable Object, and an old relay would forward it as a
frame with a bogus connId.

**ИД3. A rename is a host→relay control frame on the reserved connId `@`.**
`@\n{"t":"host.name","name":"<new name>"}`. The relay updates the host's attachment and its stored
entry, and sends the new list to every client (ПР1). Supacode also uses the new name in the URL of
its next reconnect.

Why: no reconnect, so the phones on that Mac keep their terminals. connIds are 16 hex characters,
so `@` never collides; an old relay routes it to the client tag `c:@`, finds no socket, and drops
it silently.

Rejected: reconnecting the host with the new name (drops every phone's stream on that Mac for a
cosmetic change); the name only in `hello` (the relay never parses application messages, and a
phone bound to another Mac never sees that `hello`).

**ИД4. Host name rules.** Supacode sends the trimmed `hostName` from the file, or the computer name
(`SCDynamicStoreCopyComputerName`, as today) when the key is missing or blank. Both Supacode and the
relay normalize: control characters become spaces, surrounding whitespace is trimmed, the result is
cut to 64 characters (Unicode scalars in the relay, `Character`s in Swift is fine: the relay's cut
is authoritative). An empty result means "no name" and the field is omitted.

### Relay

**РЛ1. One Durable Object with several host slots.** Keep `idFromName("default")` and the class
`RelayDO`. Tags stay as today: `host` for a host socket, `client` and `c:<connId>` for a client
socket. The host's hostId and name and the client's bound hostId live in the attachments, not in
tags, because sockets accepted before the deploy keep their old tags. Host sockets are found by the `host` tag and filtered by the attachment's
hostId.

Sockets from before the deploy: with Cloudflare's default deferred code update a hibernated object
adopts the new code with its WebSockets still open (the 30 s `ping` is auto-answered and does not
wake it). So the new code must accept the old attachments: a host attachment without `hostId`
(`{generation, ip}`) counts as `default` with no name, so an old Mac stays reachable through the
deploy. A client attachment without `hostId` (`{connId, ip}`, an old phone) counts as unbound (СВ2);
old phones are not supported (ОТ2).

Why: the host list with online state and names is answered from one place with no cross-object
calls; a personal relay has a few Macs and one or two phones; the class and its id do not change,
so there is no Durable Object migration and `wrangler.example.jsonc` stays as is.

Rejected: one Durable Object per host plus a registry object. Every online/offline/rename event
becomes an RPC to the registry, every phone needs a second socket (or a registry push) for the
list, and it adds a migration for a load that one
object serves easily.

Tag limits (Cloudflare docs, `acceptWebSocket`): at most 10 tags per socket, 256 characters each;
the relay keeps using at most two short tags.

**РЛ2. Replacement only within one hostId.** `acceptHost` closes (4000, `replaced`, after the
`replaced` text notice) only the host sockets whose attachment has the same hostId. The "false → true edge" that makes a
phone re-attach goes only to clients bound to that hostId. A host with another id is never
touched.

**РЛ3. Everything per host.**
- `conn.open` (with `sameNetwork` computed from that client's IP and the IP of its bound host) goes
  to the bound host when a client connects, and, when a host (re)connects, for every
  client bound to it.
- `conn.close` goes only to the client's bound host, and only when that host is online.
- host → client: the relay delivers `<connId>\n<json>` only when the client `connId` is bound to
  the sending socket's hostId; otherwise the frame is dropped. `*` broadcasts only to clients bound
  to the sender's hostId. `@` is a control frame (ИД3), never forwarded.
- client → host: forwarded to the newest open socket of the bound hostId; when there is none, the
  client gets `{"t":"error","id":<id>,"message":"host offline"}` as today.
- `host(hostId)` (the newest open socket by generation) replaces `host()`.

**РЛ4. Client selection in the `/client` URL query.** `wss://relay.example.com/client?host=<hostId>`
binds the socket to that hostId for its whole life. Switching hosts = closing the socket and opening
a new one with another `host`.

Why: a connId belongs to exactly one host for its whole life, so `conn.open` / `conn.close` keep
today's meaning per host and a host never sees a phone that is half-attached to another Mac. The
relay keeps forwarding client frames without parsing them. The cost is one reconnect (TLS +
Worker auth) per switch, which is a manual, rare action; it counts against the 20/min
`CONNECT_LIMIT` like any connect.

Rejected: a client→relay select frame (`{"t":"relay.select","host":…}`) on one socket. It makes the
relay parse client frames, needs a synthetic `conn.close`/`conn.open` pair on a switch while
messages for the old host may still be in flight, and an old relay would forward the frame to the
host as an unknown message.

An unknown but valid `host` binds anyway (offline): the phone shows it offline and the list lets the
owner pick another. No client is ever re-bound: the binding is fixed for the socket's life.

**РЛ5. Known hosts are remembered in Durable Object storage.** On every host accept, rename and
disconnect the relay writes `host:<hostId>` → `{"name"?: string, "lastSeen": <ms>}` (SQLite-backed
storage, already the class's backend; the async `ctx.storage` or the sync `ctx.storage.kv` API, the
implementer's choice). Offline hosts not seen for 30 days are pruned when the list is built; at
most 20 offline entries are kept (the oldest go first); online hosts are always listed and do not
count toward the cap. The legacy id `default` is listed only
while it is online and is never kept offline, so a Mac that upgrades from a legacy build does not
leave a „Mac без име“ ghost for 30 days.

Why: a list built only from open sockets cannot show "offline", which ТЛ1 asks for. The phone cannot
know Macs it never saw. Storage writes happen only on host events, never per message.

Rejected: the phone remembering hosts (it misses Macs it never connected to and cannot learn
renames of offline ones); in-memory only (lost when the object hibernates or restarts).

**РЛ6. Request validation in the Worker.** After the key check and before the upgrade, the Worker
rejects with `400 bad host id` a `/host?id=` or `/client?host=` value that does not match
`^[A-Za-z0-9_-]{1,64}$`. `name` is never a reason to reject: the relay decodes it, normalizes and
cuts it (ИД4), so a long or Cyrillic name cannot lock a host out with retries. A missing parameter is
valid (legacy host, unbound client). A 400 does not count as a failed key in `GuardDO`.

### Compatibility and rollout

**СВ1. Legacy host.** `/host` without `id` is filed as hostId `default`, with no name. It replaces
only another `default` socket. On the phone it shows as „Mac без име“ until it is upgraded.

**СВ2. A client without `host` is unbound.** `/client` without `host` binds to no host: the relay
sends `{"t":"relay","hostOnline":false,"hosts":[…]}` without `host`, sends no `conn.open` anywhere,
and answers any message from it with the usual `host offline` error. It gets every list update
(ПР1). The phone uses it only when nothing is saved (АН2) and reconnects with `?host=` once it
picks.

Why: the simplest rule that serves the new phone's first start, and the relay keeps one routing path
(bound host or none). There is no old phone to serve (ОТ2 revised).

Rejected: an automatic binding with re-binding when hosts come and go (it only served old phones
and needed its own pick order, re-bind events and tests); rejecting the upgrade with an error (the
phone would need a second request just to read the list).

**СВ3. New parts against old parts.**

| Relay | Supacode | Phone | Result |
|---|---|---|---|
| new | new | new | full feature |
| old | new | new | old relay ignores `id`, `name`, `host`; one host slot as today; the phone gets `relay` without `hosts` and runs single-host (АН1); Supacode's `@` frames are dropped |
| new | old | new | the phone sees one host `default` „Mac без име“ |

An old phone against the new relay is unbound and sees "Mac offline" until it is updated; accepted
(ОТ2 revised).

**СВ4. Rollout order.** 1) Deploy the relay and install the new phone build right after it (the old
phone does not work with the new relay). 2) Install the new Supacode on the Mac that hosts today,
then on the other Macs (copy the two config files first, see ДК1). The Macs may lag or roll back on
their own; СВ3 covers those mixes. A second Mac may host
only after step 1 (the old relay has one slot) and only with the new Supacode (an old build files
as `default` and would evict the other old build).

### Protocol

**ПР1. The `relay` message gains `host` and `hosts`.**

```json
{"t":"relay","hostOnline":true,"host":"3f9a0c1d2e4b5a69",
 "hosts":[{"id":"3f9a0c1d2e4b5a69","name":"Office Mac","online":true},
          {"id":"7c21e0b94d3a8f50","name":"Home Mac","online":false}]}
```

- `hostOnline` keeps its meaning, now for the bound host.
- `host` is the bound hostId.
- `hosts` is every known host (РЛ5), sorted by name (case-insensitive, unnamed last), then id.
  `name` is omitted when unknown.
- Sent right after the client connects; whenever the bound host goes online or offline (with the
  false → true edge on replacement, РЛ2); whenever the list changes (a host connects, disconnects,
  renames, is pruned). Each client gets its own copy (its own `host` and `hostOnline`); `host` is
  omitted for an unbound client (СВ2).
- A phone must act only on `hostOnline` edges, as today (`RelayClient.onHostOnline` already does:
  `hello` only on false → true). Repeated `hostOnline:true` messages carry list updates only.

Why the same `t`: one status message carries everything a client needs about the relay, and the
phone's decoder (`ignoreUnknownKeys = true`) already reacts only to `hostOnline` edges. Rejected: a separate `relay.hosts` message
(two messages to keep in step, and the bound `host` would still need a home).

**ПР2. `hello` gains `hostId`.** `{"t":"hello","v":1,"host":"<host name>","hostId":"<hostId>","lan":{…}}`.
`host` is now the configured host name (ИД4), not always the computer name. `hostId` is omitted when
Supacode has none (ИД1 fallback). The phone ignores `lan` when `hostId` is present and differs from
the host it selected (АН3).

**ПР3. Host → relay control frame** `@\n{"t":"host.name","name":"…"}` (ИД3). The only control frame;
the relay drops any other `@` frame.

**ПР4. Version rules.** All changes are additive and optional, so `v` stays `1` and the document
stays "wire protocol v1". Rule written into the protocol doc: `v` changes only when an existing
field changes meaning or a message the other side must understand is added; new optional fields
and new relay-only frames do not bump it. The LAN MAC input `supacode-lan-fp-v1:` is unchanged.

### LAN shortcut

**ЛН1. The LAN shortcut stays per host and needs no new trust.** Checked against today's design:
- Each Mac has its own `remote-lan/identity.p12` and its own `fp`; the phone takes `fp` from the
  `hello` of the host it is bound to and keeps no `fp` across connections.
- `fpMac` uses the shared client key; every Mac has it in `remote-client-key.txt` (ДК1). It proves
  "someone with the client key made this", not "this is Mac X". A relay that swapped one Mac's
  `hello` into another Mac's stream could steer the phone to the wrong one of the owner's own Macs,
  never to a stranger; ПР2's `hostId` check catches an honest mix-up. Binding the host into the MAC
  (`supacode-lan-fp-v2:` + hostId + fp) is rejected for now: it breaks LAN between mixed versions
  for a threat the relay can already exercise by routing.
- `sameNetwork` is computed per bound host (РЛ3). Two Macs on the phone's network each offer LAN
  only to the phones bound to them.
- On a switch the phone closes its LAN socket with the relay socket (АН3).

### Swift (Supacode)

**СУ1. Config.** `RemoteAccessConfig` gains `hostName: String?` (key `hostName`, optional, ignored when
not a string). New statics: `hostID(hardwareUUID: String?) -> String?` (ИД1),
`displayName(configured: String?, computerName: String) -> String` (ИД4), and
`hostURL(base: URL, hostID: String?, name: String) -> URL` (ИД2). The computer name lookup moves
from `RemoteHostRouter.hostName` (`RemoteHostRouter.swift:58`) into a helper both the router and the
settings pane use.

**СУ2. Host.** `RemoteRelayConnection` builds the request URL per attempt from `hostURL(…)` with its
current name (a `var`), and gets `rename(_ name: String)`: store the name; when connected, send the
ИД3 frame. `RemoteHostRouter` takes its hello name from the config (not the lazy computer name),
adds `hostId` to `RemoteHelloMessage` (omitted when nil, ПР2) for relay and LAN `hello`, and gets
`rename(to:)` that updates the hello name and calls `connection.rename`. `RemoteAccessHostController`
gets `rename(to:)` that forwards to the running router (no-op when none). The relay URL and keys are
still never logged.

**СУ3. Config file write.** `RemoteAccessConfigFile.write(enabled:lan:to:)` becomes a thin wrapper over
one `update(to:_ mutate: (inout [String: Any]) -> Void)` that keeps every other key, writes atomically
and keeps mode 0600 (today's code, `RemoteAccessSettingsClient.swift:97-117`).
`writeHostName(_ name: String?, to:)` sets `hostName` or removes it for nil/blank.
`RemoteAccessFileStatus` gains `hostName: String?` (raw from the file).

**СУ4. Client.** `RemoteAccessClient` gains `writeHostName: (String?) async throws -> Void`,
`renameHost: @MainActor (String) -> Void` (live, `RemoteAccessHostController.shared.rename`) and
`computerName: () -> String` (placeholder in the field). No restart for a rename; rejected:
`restartHost()` (drops every phone on this Mac and restarts the LAN listener for a cosmetic change).

**СУ5. Reducer (`RemoteAccessFeature`).**
- State: `hostNameDraft: String`, `computerName: String`, `isSavingHostName: Bool`.
- Actions: `hostNameDraftChanged(String)`, `hostNameSubmitted`,
  `hostNameSaved(file: RemoteAccessFileStatus)`, `hostNameSaveFailed(String)`.
- `.refreshed` updates `hostNameDraft` from the file only while the draft is not dirty (draft equals
  the last saved `file.hostName ?? ""`) and no save runs, so the 2 s poll never overwrites typing.
- `hostNameSubmitted`: trim; when equal to the saved value, do nothing; else write (blank removes the
  key), then `renameHost(displayName(draft, computerName))`, then `hostNameSaved`. Ignored when
  `!file.isConfigured`. Failure sets `errorMessage` and keeps the draft.
- One write at a time, in both orders: a name save and a toggle apply share one in-flight flag
  (`isApplying`). A name submit during an apply, or a toggle during a name save, is queued and runs
  when the running write ends (latest value per key wins), so two read-modify-writes of the file
  never overlap and neither undoes the other's key.
- Tests (TestStore, `supacodeTests/RemoteAccessSettingsTests.swift`): refresh during typing keeps the
  draft; submit unchanged writes nothing; submit new name writes and renames once; blank removes the
  key and renames to the computer name; write failure shows the error and does not rename; submit
  while not configured does nothing; a toggle during a name save and a name submit during a toggle
  apply both run after the running write and both keys end up on disk.

**СУ6. Settings view.** In `RemoteAccessSettingsView`, a "Mac name" `TextField` in the first toggles
section, placeholder = computer name, `.onSubmit` sends `hostNameSubmitted` (also on focus loss),
`.help("The name Supacode Remote shows for this Mac; applies right away")`, disabled when the file
is not configured, secondary text "Shown in Supacode Remote's list of Macs." The existing footer for
a copy that does not host becomes "Changes are saved to the configuration file; this copy of Supacode
does not host. The Mac name reaches the phone when the hosting app starts again." No custom colors or
font sizes.

**СУ7. A hand edit of `hostName` in the file** applies on the next host start (app launch or a
Settings toggle), like `lan` today; not watched live (owner decision ОТ3 = ОП13). A rename saved
from a copy of Supacode that does not host (`mayHost` false, e.g. a dev build next to the installed
app) is the same as a hand edit: the file changes, the hosting app picks it up on its next host
start; `renameHost` is a no-op there.

### Android (Supacode Remote)

**АН1. Protocol.** `RelayStatus(hostOnline, host: String? = null, hosts: List<HostInfo>? = null)`,
`HostInfo(id: String, name: String? = null, online: Boolean = false)`,
`HelloReply.hostId: String? = null`. `hosts` stays nullable so a missing field (old relay) differs from
an empty list (new relay that knows no host yet). A `relay` message with `hosts == null` means
single-host mode: no host list, no switcher, no `host` query, no selection checks; the saved
selection is kept for when a new relay comes back.

**АН2. Selection.** `SettingsStore` gets `selectedHostId: StateFlow<String?>` and
`setSelectedHostId(String?)` (plain preferences, not secret). `RelayUrl.clientUrl(base, hostId)`
appends `?host=<id>` when the id is set. A saved selection never changes by itself (owner ОП20).
With nothing saved the phone connects without `host` (unbound, СВ2) to read the list: exactly one
host online → select it (АН3); otherwise open „Mac-ове“. When a `relay` message with
`hosts != null` does not list the saved id (pruned, or the legacy `default` while offline or after
its Mac upgraded), the phone keeps the selection, shows the offline banner and opens „Mac-ове“; only
the owner's pick changes it.

**АН3. Switch.** `RelayClient.selectHost(id)`: save the id (`default` too), close the LAN session, close the relay
socket (1000), reset `hostOnline` and `hostSession`, reconnect with the new URL. `RelayClient`
exposes `hosts: StateFlow<List<HostInfo>>` and `boundHostId: StateFlow<String?>`. A `hello` whose
`hostId` differs from the bound host gets no LAN attempt (ПР2). `SessionsRepository` clears its list
when the bound host changes, so the old Mac's repos never show under the new name.

**АН4. Navigation.** New key `@Serializable data object HostsKey : NavKey` in `NavigationKeys.kt`:
screen „Mac-ове“. The Sessions top bar title shows the bound host's name and an online dot; tapping
it (content description „Смени Mac-а“) opens `HostsKey`. Picking a row calls `selectHost` and
`resetTo(SessionsKey)`, which pops any `WorktreeKey` / `TerminalKey` (their ids belong to the old
Mac). The title is plain (no tap) in single-host mode. Start screen stays `SessionsKey`.

**АН5. Texts (Bulgarian).** Screen title „Mac-ове“; row status „на линия“ / „извън линия“; unnamed
host „Mac без име“; the bound row is marked „избран“; Sessions title action „Смени Mac-а“; empty
list „Relay-ят още не познава друг Mac.“; bound host offline banner „<име> е извън линия“.

**АН6. Alerts.** Only the bound host alerts, because the phone's one socket carries only that host.
On a switch, cancel the posted awaiting notifications and reset `AwaitingTracker`. The notification
intent carries `EXTRA_HOST_ID` next to `EXTRA_CONTENT_ID`; the notification id is
`(hostId + contentId).hashCode()`. A switch cancels the old host's notifications, so the `hostId`
extra is a safety net: tapping a notification of another host switches to it, then opens
the terminal. Rejected for now: one socket per known host in `AgentWatchService` to alert from every
Mac. The relay allows it unchanged (each socket binds on its own), so it can come later.

**АН7. Docs and mock.** `docs/CONTEXT.md`: terms „Mac в списъка (HostInfo)“, „Избран Mac
(selectedHostId)“, „Свързан Mac (boundHostId)“. `tools/mock-host.mjs`: a second mock host and the
`relay` message with `host`/`hosts`, `?host=` handling. `CLAUDE.md` protocol section: the
`hostOnline` edge rule now also covers list-only `relay` messages.

### Docs (this repo)

**ДК1. `docs/remote-access.md`.** Add `hostName` to the files table; replace "One host" under
Protection with "One host per Mac" (same-Mac copies still replace each other; different Macs do
not); new section "Add another Mac": copy `remote-access.json` and `remote-client-key.txt` (mode
0600, over a private channel) to the new Mac, install Supacode under `/Applications`, set the name
in Settings → Remote Access; never run `gen-keys.mjs --force` there (it mints new keys for every
Mac). Troubleshooting: "Phone shows the wrong Mac" → pick it in „Mac-ове“; "Mac missing from the
list" → it has not connected in 30 days.

**ДК2. `gen-keys.mjs` keeps every existing key.** The rewrite becomes
`{ ...existing, enabled: existing?.enabled ?? true, relayURL, hostKey }`, so `hostName` (and `lan`,
which it drops today) survive a key rotation. `phone-sim.mjs` gets `--host <id>` and prints `hosts`.

## Tests

- **Relay (vitest).** `RelayDO` has no tests today and the package has no Workers test pool, only
  pure tests (`frames.test.ts`, `guard.test.ts`). Move the decisions into a pure module
  `src/hosts.ts` and test it in `test/hosts.test.ts`: id/name validation and normalization
  (РЛ6, ИД4); unbound client (СВ2: list without `host`, no `conn.open`, `host offline`
  error); attachments from before the deploy (no `hostId`) count as host `default` / unbound client; recipients of a host frame
  (bound only, `*` per host, foreign connId dropped, `@` handled); replacement scope (РЛ2); `relay`
  message per client (ПР1, sort, omitted name); known-host pruning (30 days, cap 20 offline, online never pruned). `RelayDO` keeps
  only socket and storage plumbing around it. DO-level tests with `@cloudflare/vitest-pool-workers`
  stay a TODO.
- **Swift.** `RemoteAccessConfigHostTests` (new): `hostName` decoding, `hostID` vector (fixed UUID →
  fixed 16 hex), `hostURL` (encoding, existing query kept, nil id), `displayName`.
  `RemoteAccessSettingsTests`: `writeHostName` keeps other keys / removes on blank / mode 0600,
  reducer cases from СУ5. `RemoteAccessProtocolTests`: hello with
  and without `hostId`; the `@` rename frame encoding. `RemoteAccessHelloWaitTests`: hello uses the
  renamed name after `rename(to:)`.
- **Android (JVM).** `ProtocolCodecTest`: `relay` with and without `hosts`/`host`, `HostInfo` without
  `name`, hello `hostId`. `RelayUrlTest`: `?host=` encoding, none when null. `RelayClientTest`:
  `selectHost` reconnects with the new URL and resets `hostSession`; nothing saved with one online host
  selects it, with several opens „Mac-ове“; a saved id missing from `hosts` keeps the selection and
  opens „Mac-ове“; `hosts` missing vs empty; list-only
  `relay` repeats do not send `hello`; old relay → single-host. `RelayLanTest`: `hello` with a foreign
  `hostId` starts no LAN. `AwaitingTrackerTest`: reset on switch.

## Implementation split

The spec is the contract: message names, fields, URL parameters and config keys above are fixed.
Each task can start now against it; the dependency column is only for live end-to-end checks.

| ID | Area | Files | Contract it implements | Live check depends on |
|---|---|---|---|---|
| ЗД1 | Relay | `remote-relay/src/relay.ts`, `src/index.ts`, new `src/hosts.ts`, `src/frames.ts` (relay message builder), new `test/hosts.test.ts`, `scripts/gen-keys.mjs`, `scripts/phone-sim.mjs` | РЛ1–РЛ6, СВ1, СВ2, ПР1, ПР3, ДК2 (scripts) | none |
| ЗД2 | Swift config + host | `RemoteRelayConnection.swift`, `RemoteHostRouter.swift`, `RemoteProtocol.swift`, `RemoteAccessHostController.swift`, `supacodeTests/RemoteAccessProtocolTests.swift`, `RemoteAccessHelloWaitTests.swift`, new `supacodeTests/RemoteAccessConfigHostTests.swift` | ИД1–ИД4, ПР2, СУ1, СУ2 | ЗД1 deployed for the relay path |
| ЗД3 | Swift Settings | `RemoteAccessSettingsClient.swift`, `RemoteAccessFeature.swift`, `Features/Settings/Views/RemoteAccessSettingsView.swift`, reducer parts of `RemoteAccessSettingsTests.swift` | СУ3–СУ7 | ЗД2 for the live rename (`rename(to:)` signature from СУ2) |
| ЗД4 | Docs | `docs/remote-access-protocol.md` (section "Multiple hosts", ПР1–ПР4, relay framing per host), `docs/remote-access.md` (ДК1) | ПР1–ПР4, ДК1 | none |
| ЗД5 | Android protocol + relay client | `protocol/Protocol.kt`, `protocol/RelayUrl.kt`, `relay/RelayClient.kt`, `settings/SettingsStore.kt`, `sessions/SessionsRepository.kt`, `AppContainer.kt`, tests in `protocol/`, `relay/`; `tools/mock-host.mjs` | АН1–АН3, ЛН1 | ЗД1 for a real relay; the mock otherwise |
| ЗД6 | Android UI + alerts | `NavigationKeys.kt`, `Navigation.kt`, new `ui/hosts/HostsScreen.kt`, `ui/sessions/SessionsScreen.kt`, `alerts/AgentAlerts.kt`, `alerts/AwaitingTracker.kt`, `MainActivity.kt`, `docs/CONTEXT.md`, `CLAUDE.md`, `AwaitingTrackerTest.kt` | АН4–АН7 | ЗД5 (`hosts`, `boundHostId`, `selectHost` API) |

ЗД2 puts its config tests (`hostName` decoding, `hostID`, `hostURL`, `displayName`) in the new
`RemoteAccessConfigHostTests.swift`, so only ЗД3 edits `RemoteAccessSettingsTests.swift`. ЗД5 and ЗД6 meet
at the `RelayClient` API named in АН3; ЗД6 may stub it until ЗД5 lands.

## Owner decisions on the open items (closed 2026-11-10)

- **ОТ1 = ОП9.** Notifications only from the selected Mac (АН6).
- **ОТ2 revised (owner, 2026-11-10).** No compatibility for old phones: the APK is only on the
  owner's phone and he updates it at once. The old-phone auto binding is dropped; a client without
  `host` is unbound (СВ2).
- **ОТ3 = ОП13.** Accepted: a hand edit of `hostName` applies on the next host start (СУ7).
- **ДК2 = ОП15.** Approved: `gen-keys.mjs` keeps every existing key, which also stops it dropping `lan`.
- **ОП18.** Accepted: a rename saved from a copy of Supacode that does not host applies on the next
  host start, as a hand edit (ОП13, СУ7).
- **ОП20.** A saved host selection never changes by itself: a saved id missing from the list opens
  „Mac-ове“; automatic selection only when nothing is saved (АН2).

## Not confirmed

- `HardwareInfo.uuid` is non-nil on every Mac the owner uses (ИД1 fallback covers nil).
- That no Android code other than `RelayClient.onHostOnline` reacts to a repeated
  `hostOnline:true` (checked only in `RelayClient.kt` and `Protocol.kt`).
