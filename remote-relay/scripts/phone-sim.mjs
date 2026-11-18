// Simulates the phone against the live relay with the client key from
// ~/.config/supacode/remote-client-key.txt. Every frame it receives is printed as one JSON line,
// prefixed with the seconds since start; an `out` frame shows its byte count instead of `b64`.
// Host and Mac names and the LAN details are replaced by "<redacted>", so the output can be shared.
// Usage: node scripts/phone-sim.mjs [--host <hostId>]                       -> hello (CAPS) + list (LAYOUT per worktree)
//        node scripts/phone-sim.mjs [--host <hostId>] --watch <seconds>     -> watch on, pushed list frames for that time
//        node scripts/phone-sim.mjs [--host <hostId>] <contentId> attach    -> attach, type a line, suggest, detach
//        node scripts/phone-sim.mjs [--host <hostId>] <contentA> <contentB> attach2
//                                   -> attach both with keep, 5 s, detach A, 3 s more (only B's out)
//        node scripts/phone-sim.mjs [--host <hostId>] <contentId> rate <seconds>  -> out frames and bytes per second
//        node scripts/phone-sim.mjs [--host <hostId>] <contentId> hold <cols> <rows>
//                                   -> attach, resize with hold, prints the size, waits for Enter, closes
//        node scripts/phone-sim.mjs [--host <hostId>] <tabId> tab-close
//        node scripts/phone-sim.mjs [--host <hostId>] <paneId> pane-split <horizontal|vertical>
//        node scripts/phone-sim.mjs [--host <hostId>] <paneId> pane-close
// Without --host the phone is unbound: it only gets the relay's host list.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
// The file holds the connection key `<relay host>/<client key>`; the key is the last segment.
const connectionKey = readFileSync(homedir() + "/.config/supacode/remote-client-key.txt", "utf8").trim();
const clientKey = connectionKey.slice(connectionKey.lastIndexOf("/") + 1);
// The relay URL lives only in the local config (wss://…/host); the phone uses /client.
const relayHost = JSON.parse(readFileSync(homedir() + "/.config/supacode/remote-access.json", "utf8")).relayURL;
const args = process.argv.slice(2);
const flag = (name) => { const i = args.indexOf(name); return i >= 0 ? args.splice(i, 2)[1] : undefined; };
const hostId = flag("--host");
const watchSeconds = flag("--watch");
const clientURL = new URL(relayHost.replace(/\/host$/, "/client"));
if (hostId) clientURL.searchParams.set("host", hostId);
const ws = new WebSocket(clientURL.toString(), { headers: { Authorization: `Bearer ${clientKey}` } });
const log = [];
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const waitFor = async (pred, ms) => { for (let i = 0; i < ms / 100 && !log.find(pred); i++) await wait(100); return log.find(pred); };
const t0 = Date.now();
const redact = (m) => {
  if (m.t === "hello") return { ...m, ...(m.host !== undefined && { host: "<redacted>" }), ...(m.lan && { lan: "<redacted>" }) };
  if (m.t === "relay" && Array.isArray(m.hosts)) return { ...m, hosts: m.hosts.map((h) => (h.name ? { ...h, name: "<redacted>" } : h)) };
  return m;
};
const show = (m) => console.log(((Date.now() - t0) / 1000).toFixed(2), JSON.stringify(redact(m)));
let outBytes = Buffer.alloc(0);
let quietOut = false; // rate mode prints per-second totals instead of every out frame
const outCount = {}; // contentId -> { frames, bytes }
ws.onmessage = (e) => {
  const m = JSON.parse(e.data === "pong" ? '{"t":"pong"}' : e.data);
  if (m.t === "out") {
    const bytes = Buffer.from(m.b64, "base64");
    if (outBytes.length < 1 << 20) outBytes = Buffer.concat([outBytes, bytes]);
    const c = (outCount[m.contentId] ??= { frames: 0, bytes: 0 });
    c.frames++; c.bytes += bytes.length;
    if (!quietOut) show({ t: "out", contentId: m.contentId, bytes: bytes.length });
    return;
  }
  log.push(m);
  show(m);
};
await new Promise((r) => (ws.onopen = r));
const send = (m) => ws.send(JSON.stringify(m));
await wait(1000);
send({ t: "hello", v: 1 }); send({ t: "list", id: 1 });
await waitFor((m) => m.t === "list", 3000);
const hello = log.find((m) => m.t === "hello");
const list = log.find((m) => m.t === "list");
const contentId = args[0] || list?.repos?.[0]?.worktrees?.[0]?.tabs?.[0]?.contentId;
const mode = args[2] === "attach2" ? "attach2" : args[1];
if (watchSeconds) {
  send({ t: "watch", id: 5, on: true });
  await wait(Number(watchSeconds) * 1000);
  send({ t: "watch", id: 5, on: false });
  await wait(500);
  console.log("PUSHED-LISTS", log.filter((m) => m.t === "list" && m.id === null).length);
} else if (mode === undefined) {
  console.log("CAPS", JSON.stringify(hello?.caps ?? null));
  for (const repo of list?.repos ?? []) {
    for (const wt of repo.worktrees ?? []) console.log("LAYOUT", JSON.stringify({ worktreeId: wt.id, name: wt.name, layout: wt.layout ?? null }));
  }
} else if (mode === "attach") {
  send({ t: "attach", id: 2, contentId, scrollback: 50 });
  await wait(2500);
  send({ t: "input", contentId, b64: Buffer.from("echo hi-from-phone-Здравей\r").toString("base64") });
  await wait(2500);
  send({ t: "suggest", id: 3, contentId });
  await waitFor((m) => m.t === "suggest" || (m.t === "error" && m.id === 3), 60000);
  send({ t: "detach", contentId });
  await wait(500);
  console.log("OUT-TEXT", JSON.stringify(outBytes.toString("utf8").replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").slice(-600)));
} else if (mode === "attach2") {
  const [a, b] = args;
  send({ t: "attach", id: 2, contentId: a, scrollback: 50, keep: true });
  send({ t: "attach", id: 3, contentId: b, scrollback: 50, keep: true });
  await wait(5000);
  const before = structuredClone(outCount);
  send({ t: "detach", contentId: a });
  await wait(3000);
  const after = (id) => ({ frames: (outCount[id]?.frames ?? 0) - (before[id]?.frames ?? 0), bytes: (outCount[id]?.bytes ?? 0) - (before[id]?.bytes ?? 0) });
  console.log("OUT-BEFORE-DETACH", JSON.stringify({ A: before[a] ?? null, B: before[b] ?? null }));
  console.log("OUT-AFTER-DETACH", JSON.stringify({ A: after(a), B: after(b) }));
} else if (mode === "rate") {
  const seconds = Number(args[2] ?? 60);
  quietOut = true;
  send({ t: "attach", id: 2, contentId, scrollback: 0 });
  // The first out is the current screen, not live output: the count starts after it.
  await waitFor((m) => m.t === "attached" || m.t === "error", 5000);
  for (let i = 0; i < 50 && !outCount[contentId]; i++) await wait(100);
  const start = { ...(outCount[contentId] ?? { frames: 0, bytes: 0 }) };
  let last = { ...start };
  for (let s = 1; s <= seconds; s++) {
    await wait(1000);
    const now = { ...(outCount[contentId] ?? { frames: 0, bytes: 0 }) };
    console.log("RATE", s, JSON.stringify({ frames: now.frames - last.frames, bytes: now.bytes - last.bytes }));
    last = now;
  }
  console.log("RATE-TOTAL", JSON.stringify({ seconds, framesPerSecond: (last.frames - start.frames) / seconds, bytesPerSecond: (last.bytes - start.bytes) / seconds }));
  send({ t: "detach", contentId });
  await wait(500);
} else if (mode === "hold") {
  const [cols, rows] = [Number(args[2]), Number(args[3])];
  send({ t: "attach", id: 2, contentId, scrollback: 0 });
  await waitFor((m) => m.t === "attached" || m.t === "error", 5000);
  send({ t: "resize", id: 3, contentId, cols, rows, hold: true });
  const size = await waitFor((m) => m.t === "size" || (m.t === "error" && m.id === 3), 10000);
  console.log("HELD", JSON.stringify(size ?? null));
  console.log("Press Enter to close the connection.");
  await new Promise((r) => { process.stdin.once("data", r); process.stdin.once("end", r); });
} else if (mode === "tab-close") {
  send({ t: "tab.close", id: 6, tabId: args[0] });
  await waitFor((m) => m.id === 6, 12000);
} else if (mode === "pane-split") {
  send({ t: "pane.split", id: 7, paneId: args[0], direction: args[2] });
  await waitFor((m) => m.id === 7, 12000);
} else if (mode === "pane-close") {
  send({ t: "pane.close", id: 8, paneId: args[0] });
  await waitFor((m) => m.id === 8, 12000);
} else {
  console.log("Unknown mode", mode);
}
const status = log.findLast((m) => m.t === "relay");
console.log("HOSTS", JSON.stringify(redact({ t: "relay", host: status?.host, hostOnline: status?.hostOnline, hosts: status?.hosts })));
ws.close(); await wait(300); process.exit(0);
