# Remote access to Supacode from a personal Android app — design

Date: 2026-11-03. Status: approved for a fast v1 (Ivan, 2026-11-03: "ВП7 да" — go from
design to local commit without waiting).

## Intent

Ivan wants to drive his Supacode sessions from his phone when he is away from the laptop.
Claude Code's own remote control is not enough: it cannot run `!` shell commands, `/btw` or
other slash commands, and it gives no access to plain shells. So the phone must be a real
terminal client: it sees exactly what a Supacode tab shows and sends every key to it. It works
for plain shells and for tabs with an agent (Claude Code, Codex, …) inside.

Personal app, never in the Play Store. Fast v1 first; non-critical edge cases go to `TODO.md`.

## Goals (v1)

1. The phone lists the same groups the Supacode sidebar shows: per repository, the main
   worktree, pinned worktrees and the other active (unpinned, not archived) worktrees.
2. Per worktree, the phone lists its tabs: title, agent badge (which agent, its activity),
   working state.
3. Opening a tab shows its live terminal and lets Ivan type into it: text, Enter, Esc, Tab,
   Ctrl+C and other control keys, arrows.
4. The terminal keeps the Mac's size. The phone never resizes the session; it renders a
   virtual terminal of the Mac's columns × rows and lets Ivan zoom and pan.
5. A "Suggest" button: Supacode runs `claude -p` with Sonnet 5.5
   (`claude-sonnet-5-5`) over the last terminal lines and returns a few short suggestions of
   what to type. Suggestions only fill the input field; nothing is sent without a tap.
6. The phone connects with one URL and one API key typed once.

## Non-goals (v1, go to TODO)

Creating tabs or worktrees from the phone, archive/pin/rename, push notifications when an
agent waits for input, several Macs, a settings UI in Supacode, Keychain storage, QR pairing,
offline cache, release signing.

## Anti-goals

- The phone must not shrink the Mac's terminal (Ivan explicitly asked for this).
- A suggestion must never be typed into the terminal on its own.
- Nothing may listen on an inbound port on the Mac.
- Nothing may deploy to the work Cloudflare account (Mentorano). Personal account only.

## Architecture

```
Android app ──WSS──▶ Cloudflare Worker "supacode-relay" ──▶ Durable Object "Relay"
                     (<subdomain>.workers.dev)                  ▲
Supacode (Mac) ──outbound WSS (host)──────────────────────────┘
   │
   ├─ app state (repositories, sidebar status, layout, TabChrome)
   └─ zmx session sockets  <ZMX_DIR>/supa-<content-uuid>
```

Decided by Ivan: Cloudflare, a Cloudflare-owned hostname (not one of his zones), the Mac side
built into Supacode, `claude -p` on the Mac for suggestions.

Builder's calls (mine), stated here so they can be checked:

### Relay (Cloudflare Worker + Durable Object)

- Worker `supacode-relay` on the personal account's `workers.dev` subdomain (URL and account
  live only in the local `remote-relay/wrangler.jsonc`). Deployed with `wrangler --profile personal`
  (the default wrangler profile is the work account).
- One Durable Object instance (`idFromName("default")`), SQLite-backed class (free plan).
- `GET /host` — WebSocket upgrade for Supacode. `GET /client` — WebSocket upgrade for the
  phone. Both authenticate with `Authorization: Bearer <key>`; the Worker compares the
  SHA-256 of the key with the secrets `HOST_KEY_SHA256` / `CLIENT_KEY_SHA256` using a
  constant-time compare. The plain keys never reach Cloudflare.
- The DO is a dumb router and never parses application messages:
  - phone → host: the DO prefixes the text frame with `<connId>\n`;
  - host → phone: the host prefixes `<connId>\n`, the DO strips it and routes;
  - the DO tells the host `<connId>\n{"t":"conn.open"}` / `{"t":"conn.close"}`;
  - the DO tells the phone `{"t":"relay","hostOnline":true|false}` on connect and whenever
    the host connects or drops.
- Hibernation WebSocket API (`ctx.acceptWebSocket` with tags), `setWebSocketAutoResponse`
  for `ping` → `pong` so keepalives do not wake the DO. Both ends send `ping` every 30 s.
- A second host connection replaces the first (close the old one).

### Supacode side ("remote access host")

- Config file `~/.config/supacode/remote-access.json` (mode 0600):
  `{"enabled": true, "relayURL": "wss://<worker>.<subdomain>.workers.dev/host", "hostKey": "…"}`.
  Read at launch. No settings UI in v1.
- An outbound WebSocket (`URLSessionWebSocketTask`) to the relay, reconnect with backoff,
  `ping` every 30 s.
- Snapshot of repositories / worktrees / tabs built on the main actor from the app store and
  `WorktreeTerminalManager` (tab titles via `TabTitle.resolved`, agents and working state via
  `TerminalTabChrome`). No new state goes into `LayoutFeature` (CLAUDE.md rule).
- Terminal streaming per attached tab, straight over the zmx session socket, never as a
  leader client:
  1. connect to `<ZMX_DIR>/supa-<content-uuid>` and do **not** send `Init` (a passive client,
     the same way `ZmxSessionWatcher` and `zmx tail` work) — so the phone never becomes
     leader and never resizes the PTY;
  2. send `Capture` (format `vt`, N scrollback rows) to get the current screen as VT bytes and
     forward it first;
  3. forward every broadcast `Output` frame;
  4. write input with tag `Send` (18) — `handleSend` queues PTY input without changing
     leadership.
- Size: the live Ghostty grid of the surface when it exists, else the persisted geometry,
  else 160×48. Re-checked every 2 s while attached; a change is pushed as a `size` message.
- Suggestions: `claude -p --model claude-sonnet-5-5` run through the user's login shell
  (`/bin/zsh -lc`) so `PATH` and the Claude login are there; input is the last ~80 plain-text
  lines (`Capture` format `plain`); output a JSON array of up to 3 strings; 90 s timeout.

### Android app

- New repo `github.com/idachev/supacode-remote`, label `Supacode Remote`, package
  `com.idachev.supacoderemote`, scaffolded by the `new-android-app` skill (official template,
  conventions of the owner's other personal Android apps, debug builds only).
- Kotlin + Compose, manual DI through `AppContainer`, OkHttp WebSocket.
- Screens: Setup (URL + API key) → Sessions (repositories with main / pinned / active
  worktrees, agent badges) → Worktree (tabs) → Terminal.
- Terminal: xterm.js bundled in assets inside a WebView, fixed to the Mac's cols × rows,
  fit to width, pinch zoom and pan. Native input bar under it: a text field with Send
  (text + Enter), a key row (Esc, Tab, Ctrl+C, Ctrl+D, ↑ ↓ ← →, Enter, `!`, `/`) and Suggest.
- The API key is stored in app-private storage (`EncryptedSharedPreferences` or DataStore).

## Wire protocol

See `docs/remote-access-protocol.md`. It is the contract between the three parts.

## Keys

Two keys, each 6 groups of 5 base32 characters (150 bits, typeable on a phone):
`HOST_KEY` lives in Supacode's config file, `CLIENT_KEY` is typed into the phone once.
Generated locally; only their SHA-256 hashes are uploaded as Worker secrets. The client key is
written to `~/.config/supacode/remote-client-key.txt` (0600) for Ivan to read.

## Left to the builder

Exact file layout inside Supacode, reconnect timings, UI details on the phone, the prompt
wording for suggestions.
