# Remote access (Android) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive every Supacode tab (shell or agent) from a personal Android app through a Cloudflare relay.

**Architecture:** A Worker + Durable Object on the personal `workers.dev` subdomain routes text frames between one host WebSocket (Supacode, outbound) and N client WebSockets (phone). Supacode answers `list` from app state and streams terminals over the zmx session socket as a passive client (`Capture` + broadcast `Output`, input with `Send`). The Android app renders the terminal with xterm.js in a WebView at the Mac's size.

**Tech Stack:** TypeScript Worker (wrangler 4, `--profile personal`), Swift 6 / TCA app code, Kotlin + Compose + OkHttp + xterm.js.

**Spec:** `docs/plans/2026-11-03-remote-access-android-design.md`, protocol `docs/remote-access-protocol.md`.

## Global Constraints

- Deploy only to the personal Cloudflare account (`wrangler --profile personal`, or the Cloudflare MCP). Never the default (Mentorano) profile.
- Suggestion model id: `claude-sonnet-5-5`, through `claude -p` on the Mac.
- The phone never sends zmx `Init`, `Input` or `Resize`; input goes with tag `Send` (18).
- Supacode code: `SupaLogger` only, `nonisolated deinit` on every main-actor class, no free functions, no new state in `LayoutFeature`, `make build-app` must pass.
- Android: package `com.idachev.supacoderemote`, repo `github.com/idachev/supacode-remote`, debug builds only, new-android-app skill conventions.

## Review Focus

1. Content id of a tab whose zmx session is gone (dead daemon) — attach must answer `detached` with a reason, not hang.
2. Host offline while the phone is open — the phone shows "Mac offline", keeps the key, reconnects when the host comes back.
3. Large bursts of output (agent redraws) — frames above the zmx 1 MiB decoder cap or WebSocket message size; chunk `out` payloads at 64 KiB.
4. Non-ASCII input (Bulgarian text, emoji) — input is bytes (UTF-8) in base64, never re-encoded.
5. The Mac sleeps / network drops — both ends reconnect with backoff; the phone re-attaches the open tab after reconnect.

---

### Task 1: Relay Worker

**Files:** Create `remote-relay/` (`package.json`, `wrangler.jsonc`, `src/index.ts`, `src/relay.ts`, `test/relay.test.ts`, `scripts/gen-keys.sh`).

**Interfaces:** Produces the endpoints and framing in `docs/remote-access-protocol.md` ("Transport", "Relay framing").

- [ ] Write unit tests for the pure helpers: `parseHostFrame("abc\n{...}")` → `{connId:"abc", json:"{...}"}`; no newline → null; `timingSafeEqualHex`.
- [ ] Implement `RelayDO` with hibernation (`acceptWebSocket`, tags `host` / `client:<id>`), `setWebSocketAutoResponse(ping→pong)`, `conn.open` replay on host connect, `relay` status to clients, `host offline` error.
- [ ] Worker `fetch`: route `/host` and `/client`, check `Authorization: Bearer` by SHA-256 vs `HOST_KEY_SHA256` / `CLIENT_KEY_SHA256`, 401 / 404.
- [ ] `scripts/gen-keys.sh`: writes `~/.config/supacode/remote-access.json` (0600, host key) and `~/.config/supacode/remote-client-key.txt` (0600), prints only the two SHA-256 hashes.
- [ ] Deploy with `wrangler deploy --profile personal`, set the two secrets, verify: no key → 401; client key on `/client` → `{"t":"relay","hostOnline":false}`.
- [ ] Commit.

### Task 2: Supacode host — connection and list

**Files:** Create `supacode/Features/RemoteAccess/` — `RemoteAccessConfig.swift` (load JSON file), `RemoteRelayConnection.swift` (URLSessionWebSocketTask, ping 30 s, backoff 1→30 s), `RemoteHostRouter.swift` (`@MainActor`, per-message dispatch), `RemoteSnapshotBuilder.swift` (pure: builds the `list` payload from repositories, sidebar status, layouts and a chrome lookup), `RemoteProtocol.swift` (Codable messages). Modify `supacode/App/supacodeApp.swift` (start the host after `configureSocketHandlers`), `TerminalContent` (expose `gridSize`). Test: `supacodeTests/RemoteAccess/RemoteSnapshotBuilderTests.swift`, `RemoteProtocolTests.swift`.

**Interfaces:**
- `RemoteHostFrame.parse(_ text: String) -> (connID: String, json: Data)?`, `RemoteHostFrame.encode(connID:payload:) -> String`.
- `RemoteSnapshotBuilder.build(repositories:status:layouts:tabInfo:) -> RemoteListPayload` (order: main, pinned, unpinned; archived dropped).

- [ ] Tests for frame parse/encode, snapshot ordering and archived filter, agent raw values.
- [ ] Implement, wire `hello` / `list` / `error`.
- [ ] `make build-app` and the new tests pass. Commit.

### Task 3: Supacode host — terminal stream, input, suggest

**Files:** Create `supacode/Features/RemoteAccess/ZmxRemoteStream.swift` (passive socket client: connect, `Capture` vt request, forward `Output`, `Send` input, close), `RemoteSuggestionRunner.swift` (`claude -p` through `/bin/zsh -lc`, 90 s timeout, parse JSON array). Test: `ZmxRemoteStreamTests.swift` (frame encode of `Capture` / `Send` headers: 8-byte header, tag, LE length), `RemoteSuggestionRunnerTests.swift` (parse fenced / bare JSON arrays, cap 3).

**Interfaces:** `ZmxIPCFrameEncoder.frame(tag: UInt8, payload: [UInt8]) -> [UInt8]`; `ZmxRemoteStream(sessionSocketPath:onOutput:onClose:)` with `start(scrollback:)`, `send(_ bytes: [UInt8])`, `stop()`.

- [ ] Tests first, then implementation; `attach` / `detach` / `input` / `suggest` routed; `size` polled every 2 s; one attachment per conn.
- [ ] Live check against a real `supa-*` session with a small script through the relay. Commit.

### Task 4: Android app

**Files:** New repo `github.com/idachev/supacode-remote` via the `new-android-app` skill.

- [ ] Scaffold with the template; `build-project.sh`, `scripts/deploy-apk.sh`, `CLAUDE.md`, `docs/CONTEXT.md`, `AppContainer`.
- [ ] `RelayClient` (OkHttp WebSocket, ping 30 s, reconnect, `StateFlow` of connection + messages), protocol models (kotlinx.serialization), unit tests for parsing the protocol examples.
- [ ] Screens: Setup, Sessions, Worktree tabs, Terminal (xterm.js asset, fixed cols × rows, fit-to-width, pinch zoom, key row, input field, Suggest chips).
- [ ] Unit tests + debug APK build; run in the emulator against the live relay and the Mac; deploy APK to Dropbox. Commit.

### Task 5: End-to-end check and docs

- [ ] Emulator: Setup → list shows the same groups as the sidebar → open a shell tab, type `echo hi` → open a Claude tab, run `!pwd`, `/btw` → Suggest fills the field.
- [ ] Mac terminal size unchanged after typing from the phone.
- [ ] `docs/fork.md` section "Remote access", TODO entries only for what is left. Commit.
