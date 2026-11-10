// Pure helpers for the relay framing in docs/remote-access-protocol.md.
import type { HostInfo } from "./hosts";

/** A host frame is `<connId>\n<json>`. Returns null when the prefix is missing. */
export function parseHostFrame(text: string): { connId: string; json: string } | null {
  const newline = text.indexOf("\n");
  if (newline <= 0) return null;
  return { connId: text.slice(0, newline), json: text.slice(newline + 1) };
}

export function encodeHostFrame(connId: string, json: string): string {
  return `${connId}\n${json}`;
}

/** Best-effort read of a request `id`, so a "host offline" error can echo it. */
export function requestId(json: string): number | null {
  try {
    const value = JSON.parse(json) as { id?: unknown };
    return typeof value.id === "number" ? value.id : null;
  } catch {
    return null;
  }
}

/**
 * Whether two client IPs are most likely behind the same router: equal IPv4
 * addresses, or IPv6 addresses in the same /64. Only a hint for trying a LAN
 * connection; the phone always falls back to the relay.
 */
export function sameNetwork(a: string | null, b: string | null): boolean {
  if (!a || !b) return false;
  const v6 = (ip: string) => ip.includes(":");
  if (v6(a) !== v6(b)) return false;
  if (!v6(a)) return a === b;
  return ipv6Prefix64(a) === ipv6Prefix64(b);
}

/** The first four hextets of an IPv6 address, expanded and lower-cased. */
export function ipv6Prefix64(ip: string): string {
  const [head, tail = ""] = ip.toLowerCase().split("::");
  const left = head ? head.split(":") : [];
  const right = ip.includes("::") && tail ? tail.split(":") : [];
  const missing = 8 - left.length - right.length;
  const full = ip.includes("::") ? [...left, ...Array(Math.max(missing, 0)).fill("0"), ...right] : left;
  return full.slice(0, 4).map((h) => (h || "0").replace(/^0+(?=.)/, "")).join(":");
}

/** The host-side announcement of a new phone, with the same-network hint. */
export function connOpen(sameNet: boolean): string {
  return JSON.stringify({ t: "conn.open", sameNetwork: sameNet });
}

/**
 * The relay status message (ПР1). `host` is the client's bound hostId (omitted
 * for an unbound client) and `hosts` every known host; both are omitted when
 * not given.
 */
export function relayStatus(hostOnline: boolean, extra: { host?: string; hosts?: HostInfo[] } = {}): string {
  const message: { t: "relay"; hostOnline: boolean; host?: string; hosts?: HostInfo[] } = { t: "relay", hostOnline };
  if (extra.host !== undefined) message.host = extra.host;
  if (extra.hosts !== undefined) message.hosts = extra.hosts;
  return JSON.stringify(message);
}

export function hostOfflineError(id: number | null): string {
  return JSON.stringify({ t: "error", id, message: "host offline" });
}

export function randomConnId(): string {
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Constant-time compare of two hex strings of any length. */
export function timingSafeEqualHex(a: string, b: string): boolean {
  const left = a.toLowerCase();
  const right = b.toLowerCase();
  let diff = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let i = 0; i < length; i++) {
    diff |= (left.charCodeAt(i) || 0) ^ (right.charCodeAt(i) || 0);
  }
  return diff === 0;
}

/** `Authorization: Bearer <key>` → key, else null. */
export function bearerKey(header: string | null): string | null {
  if (!header) return null;
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  return match ? match[1].trim() : null;
}
