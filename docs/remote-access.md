# Remote access: setup and operations

How to run the remote access relay and connect the personal Android app ("Supacode Remote") to
Supacode. Design: `docs/plans/done/2026-11-03-remote-access-android-design.md`. Wire protocol:
`docs/remote-access-protocol.md`. Fork notes: `docs/fork.md` → "Remote Access From The Android App".

Nothing account-specific is in git: no relay URL, no account ID, no keys. They live only in local,
gitignored files:

| File | What it holds |
|---|---|
| `remote-relay/wrangler.jsonc` | Worker name and, if needed, `account_id` (copied from `wrangler.example.jsonc`) |
| `~/.config/supacode/remote-access.json` (0600) | `enabled`, `relayURL` (`wss://…/host`), `hostKey`, optional `lan`, optional `hostName` (the name the phone shows for this Mac) |
| `~/.config/supacode/remote-client-key.txt` (0600) | the connection key of a client, the phone or another Supacode's "Remote Mac" window: `<relay host>/<client key>` |
| Worker secrets `HOST_KEY_SHA256`, `CLIENT_KEY_SHA256` | SHA-256 hashes of the two keys, never the keys |

`$XDG_CONFIG_HOME/supacode` replaces `~/.config/supacode` when set.

## First setup

Run from `remote-relay/`. Use your own Wrangler profile (`--profile <name>`, or none for the
default one); the examples use `personal`.

1. Install the dependencies:

   ```sh
   npm install
   ```

2. Create the local Wrangler config from the template. Change `name` if you want another Worker
   name. Add `"account_id"` only if your profile can see more than one account:

   ```sh
   cp wrangler.example.jsonc wrangler.jsonc
   ```

3. Deploy. Wrangler prints the URL, `https://<name>.<your subdomain>.workers.dev`:

   ```sh
   npx wrangler deploy --profile personal
   ```

4. Create the keys and the local Supacode config with that URL. The script prints only the two
   hashes:

   ```sh
   node scripts/gen-keys.mjs --relay https://<name>.<your subdomain>.workers.dev
   ```

5. Store the two hashes as Worker secrets. Each command asks for the value; paste the matching
   hash from step 4:

   ```sh
   npx wrangler secret put HOST_KEY_SHA256 --profile personal
   ```

   ```sh
   npx wrangler secret put CLIENT_KEY_SHA256 --profile personal
   ```

6. Restart Supacode. It reads `remote-access.json` at launch and connects to the relay.

7. Check that the Mac is online and the list comes back:

   ```sh
   node scripts/phone-sim.mjs
   ```

   Without `--host` the simulator is not bound to a Mac: among its output is the `HOSTS` list. Take the
   `id` of your Mac from it and run again:

   ```sh
   node scripts/phone-sim.mjs --host <hostId>
   ```

   Expect `"hostOnline":true` and the sidebar's sections.

8. On the phone, open "Настройка", paste the connection key from
   `~/.config/supacode/remote-client-key.txt` into "Ключ за връзка", then "Запази и свържи". The
   connection key is the relay host, a slash and the client key
   (`relay.example.com/abcde-fghij-…`), so the APK holds no relay address.

## Name this Mac

The phone lists every Mac by name. The name is the optional key `hostName` in
`~/.config/supacode/remote-access.json`; when it is missing or blank, the Mac's computer name is
used.

- In Supacode: Settings → Remote Access → "Mac name". The field writes `hostName` and keeps every
  other key. A blank field removes the key. The new name reaches the phone within seconds, without
  dropping its terminals. The field is disabled until the config file exists.
- By hand: set `"hostName": "Office Mac"` in the file. A hand edit applies the next time the hosting
  app starts (app launch or a Settings toggle), like `lan`.
- A copy of Supacode that does not host (a dev build next to the installed app) saves the name to the
  file, but the hosting app picks it up only on its next start.
- The name is trimmed, control characters become spaces, and it is cut to 64 characters.

## Add another Mac

One relay and one key pair serve every Mac. The Mac's identity on the relay (`hostId`) is derived
from its hardware, so a copied config does not make two Macs evict each other.

1. Copy `~/.config/supacode/remote-access.json` and `~/.config/supacode/remote-client-key.txt` to
   the same folder on the new Mac, over a private channel (they hold the keys). If the first Mac's
   file has a `hostName`, the copy carries it: delete that key from the copy now, before Supacode
   starts, to show the new Mac's computer name (a hand edit after the start applies only at the next
   host start). Set mode 0600 on both:

   ```sh
   chmod 600 ~/.config/supacode/remote-access.json ~/.config/supacode/remote-client-key.txt
   ```

2. Install Supacode under `/Applications` (only the installed app hosts) and start it.
3. Or set a new name in Settings → Remote Access → "Mac name"; it applies at once.
4. On the phone, open „Mac-ове“ and pick the Mac.

Do not run `node scripts/gen-keys.mjs --force` (in `remote-relay/`) on the new Mac: it mints new keys, which stop every
other Mac and the phone. Roll out in this order: relay, phone, then Supacode on each Mac. A second
Mac needs the new relay and the new Supacode (an old build files as `default` and would evict the
other old build).

## Own domain and WAF rate limiting (optional)

A relay on your own Cloudflare zone lets a WAF rate limiting rule stop floods before the Worker
runs; blocked requests then do not count toward the Worker's quota. On the Free plan it costs
nothing: a Workers Custom Domain adds the DNS record, Universal SSL covers the name, and the zone
gets 1 rate limiting rule (10 s period, 10 s block).

1. In the local `wrangler.jsonc`, add the route and turn the `workers.dev` address off, so the
   rule cannot be bypassed:

   ```jsonc
   "workers_dev": false,
   "routes": [{ "pattern": "relay.example.com", "custom_domain": true }],
   ```

2. Deploy (`npx wrangler deploy --profile personal`).
3. In the zone, create a rate limiting rule (Security → Security rules → Rate limiting rules):
   expression `(http.host eq "relay.example.com")`, characteristics IP, 10 requests per 10 s,
   action Block for 10 s.
4. Point Supacode and the phone at the new host; the keys stay:

   ```sh
   node scripts/gen-keys.mjs --relay https://relay.example.com
   ```

   Restart Supacode and paste the new connection key on the phone.

## Rotate the keys

Rotate when a key may have leaked, or when a phone is lost.

1. Create two new keys; the relay URL in the config stays:

   ```sh
   node scripts/gen-keys.mjs --force
   ```

2. Store both new hashes as secrets (paste the hashes the first command printed):

   ```sh
   npx wrangler secret put HOST_KEY_SHA256 --profile personal
   ```

   ```sh
   npx wrangler secret put CLIENT_KEY_SHA256 --profile personal
   ```

3. Restart Supacode, so it connects with the new host key. With several Macs, copy the new
   `remote-access.json` and `remote-client-key.txt` to each of them first (see "Add another Mac"),
   keeping each Mac's own `hostName`.
4. Paste the new connection key on the phone. Old keys stop working as soon as the secrets change.

To print the current hashes again without changing anything, run `node scripts/gen-keys.mjs`.

## Turn remote access off

Set `"enabled": false` in `~/.config/supacode/remote-access.json` and restart Supacode. To stop
everyone, also delete the Worker (`npx wrangler delete --profile personal`).

## Protection

- **Keys.** 30 random symbols from a 32-letter alphabet (150 bits). The Worker compares SHA-256
  hashes in constant time.
- **WAF rate limit** (own domain only): more than 10 requests per 10 s from one IP get `429` at
  Cloudflare's edge, before the Worker runs.
- **Rate limit.** At most 20 connection attempts per client IP per minute (`CONNECT_LIMIT`,
  Workers Rate Limiting, per Cloudflare location); more get `429` before any key check.
- **Failed keys.** 5 wrong or missing keys from one IP within 10 minutes block that IP for 1 hour
  (`GuardDO`, one Durable Object per IP); a blocked IP gets `403`. A correct key clears the
  earlier failures. Mobile carriers share IPs, so someone else's failures can block you too.
- **One host per Mac.** A new host connection replaces the old one only when both come from the
  same Mac (same `hostId`); the replaced Supacode stops instead of reconnecting, so two instances
  never flap. Different Macs do not replace each other. Anyone with the host key may still claim any
  host id: the trust is the same as before.
- **Only the installed app hosts.** Every Supacode on the Mac reads the same config, so only the
  app under `/Applications` (or `~/Applications`) connects to the relay. A dev build from
  DerivedData or an agent's test copy stays off, unless started with `SUPACODE_REMOTE_ACCESS=1`;
  `SUPACODE_REMOTE_ACCESS=0` turns the installed app off for one launch.
- **Suggestions** run `claude -p` only on the Mac and only for an authenticated phone.

## LAN shortcut

When the phone and the Mac are on the same network, the phone talks to the Mac directly and skips
Cloudflare (protocol: `docs/remote-access-protocol.md` → "LAN shortcut").

- The relay tells Supacode when a phone's public IP matches the Mac's; Supacode then offers its
  IPv4 addresses of its Wi-Fi/Ethernet (`en*`) interfaces and a listening port in the `hello` reply.
- Supacode listens on a random port on all interfaces except cellular and accepts any source
  address. The protection is the pinned certificate and the client key (below), at most 8 LAN
  phones at a time, and a 10 s limit to finish TLS and the upgrade. macOS may ask once to allow
  incoming connections.
- The link is standard TLS 1.3 with a self-signed certificate that Supacode creates on first use.
  The phone pins its SHA-256 fingerprint, which it gets through the relay together with an HMAC
  made with the client key, so the relay cannot swap it. The phone then sends the client key in
  `Authorization`, inside TLS.
- Turn it off with `"lan": false` in `~/.config/supacode/remote-access.json` (restart Supacode).
- If the direct connection fails or drops, the phone stays on, or goes back to, the relay.

## Use another Mac from Supacode

Besides the phone, Supacode itself can show another Mac's Supacode in a window: its sidebar, tabs and
splits, each pane a real terminal. Each Mac gets its own window, so several Macs can be open at once. Design: `docs/plans/2026-11-17-remote-client-design.md`; the code
is described in `docs/fork.md` → "Remote Client Window".

Both Macs need the same relay and key pair, as for the phone. The Mac you open (the "host") must
run a Supacode with remote access on, from `/Applications`, and a build new enough for this window;
an older one shows "<Mac> runs an older Supacode". The Mac you work on (the "client") needs only the
key file; it need not host anything.

1. Copy `~/.config/supacode/remote-client-key.txt` from the host (or from any Mac that already has
   it) to the same folder on the client, over a private channel, and set mode 0600:

   ```sh
   chmod 600 ~/.config/supacode/remote-client-key.txt
   ```

   The file is one line, `<relay host>/<client key>` (`relay.example.com/abcde-fghij-…`). Without
   it the window shows "No connection key", the path to put the file at, and **Check Again**.

2. File ▸ **Open Remote Mac…** (⌃⌘O). The window is called "Remote Mac". With no Remote Mac window
   open it opens the Mac you picked last; with one open, it opens a new window for another Mac.
3. Pick the Mac. The window lists the Macs that are on the relay, by name ("Office Mac", "Home
   Mac"; see "Name this Mac"), never the Mac you are on and never a Mac another window already
   shows. With nothing picked yet and exactly one such Mac online, it picks that one. Otherwise it
   shows "Choose a Mac". Later, click the title (the Mac's name) to show another Mac in this window.
   The last pick is saved for the next "Open Remote Mac…" with no window open. A window never
   switches Mac on its own: when its Mac is no longer in the relay's list, it opens the picker, and
   a Mac that is listed but not online shows "<Mac> is offline".

   A Mac is never open in two windows: opening it again (from the menu, the picker or a
   notification) brings its window forward. Each window has its own connection, so four windows
   are four connections to the relay; closing a window disconnects only its Mac, and quitting
   Supacode disconnects them all.
4. Work as on the Mac itself: the sidebar, tabs and splits are the host's, and what you do in the
   window (a new tab, a split, a close, a new worktree) is done on the host, without a confirmation
   there. Each terminal is the host's real terminal, sized to its pane here.

Next to the Mac's name in the title is the path in use ("Office Mac · LAN"): **LAN** when both Macs
are on the same network (see "LAN shortcut": the relay tells the host, the host offers its address
and the window pins the certificate), otherwise **Relay**. While there is no live link, the line
under the name is the banner's notice instead (see "What the banner means"). When the direct path fails, the window uses the
relay again and goes back to LAN when it can.

While a Remote Mac window is key, the menus act on the Mac it shows: New Terminal (⌘T), Close (⌘W),
the splits and zoom, Select Tab (⌘1 to ⌘9, previous, next), and the Worktrees menu (new, refresh,
next and previous worktree, select by slot). Items that have no meaning there are disabled, for
example Add Repository and Clone, Archived Worktrees, Recent Terminals, Jump to Latest Unread and
the worktree history.

### What the banner means

A line above each remote terminal, repeated under the title, tells why the terminal is not live:

- **Connecting to <Mac>…**: the link is coming up, or coming back, and the terminal has not been
  redrawn yet. A terminal that never gets its first redraw stays here: a host that never answers
  `hello` also stays in "Connecting…" (a known limit).
- **<Mac> is offline.**: the relay is up, but the host is not on it. The window connects again by
  itself when the host comes back.
- **No connection to <Mac>. Typing is not sent.**: this Mac has no live link to the relay. Typing is
  dropped, never queued, also while the window attaches again; nothing you type now reaches the
  host later.

How fast it shows: a dead link is found when no frame (a `pong` counts) has come for 75 s, checked at
each 30 s ping, so the banner appears within 75 to 105 s of the link dying, not at once. The window
then retries after 3, 6 and 12 s, and every 30 s after that. A key the relay refuses (`401` or `403`,
see "Troubleshooting") is not retried: the window shows "Cannot connect to <Mac>" with the relay's
status and **Try Again**, and that status is the only sign of it.

### Notifications

When an agent in a tab of the remote Mac starts waiting for input, this Mac posts one system
notification, "<Mac> — agent is waiting", with the worktree and tab title. It is posted only when
system notifications are on in Supacode's settings and the tab is not visible in the key Remote Mac
window; a tab that stays waiting gives no second one. Clicking it brings the window of that Mac
forward and opens that tab; when no window shows that Mac (a notification left from before a
relaunch), a window opens for it, without selecting the tab. The notification goes away when the
tab stops waiting, and when the window of its Mac closes or switches to another Mac.

## Troubleshooting

- **Phone shows "Mac offline"**: Supacode is not running, `enabled` is false, or another Supacode
  instance on the same Mac took this Mac's host slot (the replaced one logs "Another Supacode
  instance is the remote access host now"). Restart Supacode. Another Mac never takes the slot.
- **Phone shows the wrong Mac**: pick the right one in „Mac-ове“. The phone remembers the last pick.
- **A Mac is missing from the list**: it has not connected for 30 days, so the relay dropped it (the
  relay also keeps at most 20 offline Macs). Start Supacode on it. A „Mac без име“ entry is a
  Supacode build that is not updated yet.
- **Two Macs show the same name**: give them different names in Settings → Remote Access → "Mac name".
- **`401` on connect**: the key does not match the secret. Print the hashes with
  `node scripts/gen-keys.mjs` (run from `remote-relay/`) and set the secrets again.
- **`403` on connect**: the IP is blocked for an hour after 5 failed keys. Wait, or connect from
  another network.
- **A second Supacode for tests** needs `CFFIXED_USER_HOME=<dir>` and `ZMX_DIR=<short dir>`
  (Foundation ignores `HOME`); otherwise it shares `~/.supacode` state and zmx sessions with the
  real app. It connects to the relay only with `SUPACODE_REMOTE_ACCESS=1`, and then it takes the
  host slot of this Mac from the installed app until that one restarts. Add
  `SUPACODE_REMOTE_HOST_ID=<id>` (1 to 64 characters of `A-Z a-z 0-9 _ -`, honoured only together
  with `SUPACODE_REMOTE_ACCESS=1`) and that copy gets its own place on the relay, so it does not
  take the installed app's slot.
