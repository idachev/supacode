// Simulates the phone against the live relay with the client key from
// ~/.config/supacode/remote-client-key.txt.
// Usage: node scripts/phone-sim.mjs            -> hello + list
//        node scripts/phone-sim.mjs <contentId> attach  -> attach, type a line, suggest, detach
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
// The file holds the connection key `<relay host>/<client key>`; the key is the last segment.
const connectionKey = readFileSync(homedir() + "/.config/supacode/remote-client-key.txt", "utf8").trim();
const clientKey = connectionKey.slice(connectionKey.lastIndexOf("/") + 1);
// The relay URL lives only in the local config (wss://…/host); the phone uses /client.
const relayHost = JSON.parse(readFileSync(homedir() + "/.config/supacode/remote-access.json", "utf8")).relayURL;
const ws = new WebSocket(relayHost.replace(/\/host$/, "/client"), { headers: { Authorization: `Bearer ${clientKey}` } });
const log = [];
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
let outBytes = Buffer.alloc(0);
ws.onmessage = (e) => {
  const m = JSON.parse(e.data === "pong" ? '{"t":"pong"}' : e.data);
  if (m.t === "out") { outBytes = Buffer.concat([outBytes, Buffer.from(m.b64, "base64")]); return; }
  log.push(m);
};
await new Promise((r) => (ws.onopen = r));
const send = (m) => ws.send(JSON.stringify(m));
await wait(1000);
send({ t: "hello", v: 1 }); send({ t: "list", id: 1 });
await wait(2000);
const list = log.find((m) => m.t === "list");
console.log("LIST", JSON.stringify(list, null, 1));
const contentId = process.argv[2] || list?.repos?.[0]?.worktrees?.[0]?.tabs?.[0]?.contentId;
if (process.argv[3] === "attach") {
  send({ t: "attach", id: 2, contentId, scrollback: 50 });
  await wait(2500);
  send({ t: "input", contentId, b64: Buffer.from("echo hi-from-phone-Здравей\r").toString("base64") });
  await wait(2500);
  send({ t: "suggest", id: 3, contentId });
  for (let i = 0; i < 60 && !log.find((m) => m.t === "suggest" || (m.t === "error" && m.id === 3)); i++) await wait(1000);
  send({ t: "detach", contentId });
  await wait(500);
}
console.log("MSGS", JSON.stringify(log.filter((m) => m.t !== "list")));
console.log("OUT-TEXT", JSON.stringify(outBytes.toString("utf8").replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").slice(-600)));
ws.close(); await wait(300); process.exit(0);
