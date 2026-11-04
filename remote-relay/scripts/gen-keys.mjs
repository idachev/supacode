#!/usr/bin/env node
// Generates the host and client keys for the Supacode relay.
// Writes them only to ~/.config/supacode (mode 0600) and prints only their
// SHA-256 hashes, which are what the Worker secrets hold. See docs/remote-access.md.
// The client key file holds the phone's connection key, `<relay host>/<client key>`.
// Usage:
//   node scripts/gen-keys.mjs --relay https://<worker>.<subdomain>.workers.dev   first run
//   node scripts/gen-keys.mjs                                                    print hashes again
//   node scripts/gen-keys.mjs --force [--relay <url>]                            rotate both keys
import { createHash, randomInt } from "node:crypto";
import { existsSync, mkdirSync, writeFileSync, readFileSync, chmodSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const ALPHABET = "abcdefghijkmnpqrstuvwxyz23456789"; // 32 symbols, no l/o/0/1
const dir = join(homedir(), ".config", "supacode");
const configPath = join(dir, "remote-access.json");
const clientKeyPath = join(dir, "remote-client-key.txt");
const force = process.argv.includes("--force");
const relayArg = process.argv[process.argv.indexOf("--relay") + 1];

/** https://x.workers.dev (or wss://…/host) -> wss://x.workers.dev/host */
function hostURL(base) {
  const url = new URL(base);
  url.protocol = url.protocol === "http:" || url.protocol === "ws:" ? "ws:" : "wss:";
  url.pathname = "/host";
  return url.toString();
}

function newKey() {
  const groups = [];
  for (let g = 0; g < 6; g++) {
    let group = "";
    for (let i = 0; i < 5; i++) group += ALPHABET[randomInt(ALPHABET.length)];
    groups.push(group);
  }
  return groups.join("-");
}

/** `<host>/<key>`; the scheme is kept only when it is not https (a local test relay). */
function connectionKey(hostURLString, key) {
  const url = new URL(hostURLString);
  const scheme = url.protocol === "ws:" ? "http://" : "";
  return `${scheme}${url.host}/${key}`;
}

/** The client key alone, from a connection key or an older bare key file. */
function bareKey(text) {
  return text.slice(text.lastIndexOf("/") + 1);
}

const sha256 = (text) => createHash("sha256").update(text).digest("hex");

mkdirSync(dir, { recursive: true, mode: 0o700 });
let hostKey;
let clientKey;
const existing = existsSync(configPath) ? JSON.parse(readFileSync(configPath, "utf8")) : null;
const relayURL = process.argv.includes("--relay") ? hostURL(relayArg) : existing?.relayURL;
if (!relayURL) {
  console.error("No relay URL yet: pass --relay https://<worker>.<subdomain>.workers.dev");
  process.exit(2);
}
if (!force && existing && existsSync(clientKeyPath)) {
  hostKey = existing.hostKey;
  clientKey = bareKey(readFileSync(clientKeyPath, "utf8").trim());
} else {
  hostKey = newKey();
  clientKey = newKey();
}
// The phone gets one connection key: the relay's host, a slash, then the
// client key (see docs/remote-access.md). The APK holds no relay address.
writeFileSync(clientKeyPath, connectionKey(relayURL, clientKey) + "\n", { mode: 0o600 });
writeFileSync(configPath, JSON.stringify({ enabled: existing?.enabled ?? true, relayURL, hostKey }, null, 2) + "\n", { mode: 0o600 });
chmodSync(configPath, 0o600);
chmodSync(clientKeyPath, 0o600);
process.stdout.write(JSON.stringify({ HOST_KEY_SHA256: sha256(hostKey), CLIENT_KEY_SHA256: sha256(clientKey) }) + "\n");
