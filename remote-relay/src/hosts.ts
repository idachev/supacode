// Pure host-slot decisions for the relay (docs/plans/2026-11-10-remote-multi-host-design.md,
// РЛ1–РЛ6, СВ1, СВ2, ПР1, ПР3). `RelayDO` keeps only the socket and storage plumbing around them.
// This module must stay free of `cloudflare:workers` so vitest can import it.

/** The hostId of a host that connects without `id` (a legacy Supacode build, СВ1). */
export const LEGACY_HOST_ID = "default";

/** connId of the host → relay control frame (ИД3, ПР3). */
export const CONTROL_CONN_ID = "@";

/** Valid `/host?id=` and `/client?host=` values (РЛ6). */
const HOST_ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;

/** Longest host name in Unicode scalars (ИД4). */
export const MAX_HOST_NAME_LENGTH = 64;

/** Offline hosts not seen for this long are pruned (РЛ5). */
export const OFFLINE_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;

/** At most this many offline hosts are kept; the oldest go first (РЛ5). */
export const MAX_OFFLINE_HOSTS = 20;

/** Durable Object storage key prefix of a known host (РЛ5). */
export const KNOWN_HOST_PREFIX = "host:";

/** One host in the `relay` message (ПР1). */
export interface HostInfo {
  id: string;
  name?: string;
  online: boolean;
}

/** The stored entry `host:<hostId>` (РЛ5). */
export interface KnownHost {
  name?: string;
  lastSeen: number;
}

/**
 * A host socket's attachment. Sockets accepted before the multi-host deploy
 * carry only `{generation, ip}` and count as `default` with no name (РЛ1).
 */
export interface HostAttachment {
  /** Accept time; the highest one is the current socket of its hostId. */
  generation: number;
  ip?: string | null;
  hostId?: string;
  name?: string;
}

/**
 * A client socket's attachment. A missing or null `hostId` (an old phone, or
 * `/client` without `host`) means unbound (СВ2).
 */
export interface ClientAttachment {
  connId: string;
  /** CF-Connecting-IP, for the same-network hint. */
  ip?: string | null;
  hostId?: string | null;
}

export function isValidHostId(value: string): boolean {
  return HOST_ID_PATTERN.test(value);
}

/**
 * ИД4: control characters become spaces, surrounding whitespace is trimmed,
 * the result is cut to 64 Unicode scalars. An empty result means no name.
 */
export function normalizeHostName(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const cleaned = raw.replace(/\p{Cc}/gu, " ").trim();
  const cut = Array.from(cleaned).slice(0, MAX_HOST_NAME_LENGTH).join("");
  return cut.length > 0 ? cut : undefined;
}

export type HostRequest = { role: "host"; hostId: string; name?: string };
export type ClientRequest = { role: "client"; hostId: string | null };

/**
 * Reads the multi-host query of a `/host` or `/client` URL (ИД2, РЛ4).
 * Returns null when `id` / `host` is present but invalid (РЛ6: `400 bad host id`);
 * a missing parameter is valid (legacy host, unbound client). `name` never fails.
 */
export function parseConnectRequest(url: URL): HostRequest | ClientRequest | null {
  if (url.pathname === "/host") {
    const id = url.searchParams.get("id");
    if (id === null) return { role: "host", hostId: LEGACY_HOST_ID }; // СВ1: no name either
    if (!isValidHostId(id)) return null;
    return { role: "host", hostId: id, name: normalizeHostName(url.searchParams.get("name")) };
  }
  const host = url.searchParams.get("host");
  if (host !== null && !isValidHostId(host)) return null;
  return { role: "client", hostId: host };
}

/** A host attachment without `hostId` (from before the deploy) is the legacy host. */
export function hostIdOf(attachment: HostAttachment | null | undefined): string {
  return attachment?.hostId ?? LEGACY_HOST_ID;
}

/** The hostId a client socket is bound to, or null when unbound. */
export function boundHostOf(attachment: ClientAttachment | null | undefined): string | null {
  return attachment?.hostId ?? null;
}

/** A host socket as the decisions below see it. */
export interface HostSocketView<T> {
  socket: T;
  attachment: HostAttachment | null;
  open: boolean;
}

/** РЛ3: the newest open socket of `hostId`, skipping `except` (a socket that is closing). */
export function newestHost<T>(sockets: readonly HostSocketView<T>[], hostId: string, except?: T): HostSocketView<T> | null {
  let newest: HostSocketView<T> | null = null;
  for (const view of sockets) {
    if (view.socket === except || !view.open || hostIdOf(view.attachment) !== hostId) continue;
    if (newest === null || (view.attachment?.generation ?? 0) > (newest.attachment?.generation ?? 0)) newest = view;
  }
  return newest;
}

/**
 * Every online host with the name of its newest socket. `except` is a socket
 * that is closing and may still read as open.
 */
export function onlineHosts<T>(sockets: readonly HostSocketView<T>[], except?: T): Map<string, string | undefined> {
  const online = new Map<string, string | undefined>();
  const ids = new Set(sockets.map((view) => hostIdOf(view.attachment)));
  for (const id of ids) {
    const newest = newestHost(sockets, id, except);
    if (newest) online.set(id, newest.attachment?.name);
  }
  return online;
}

/** РЛ2: the sockets a new host socket replaces — only those with the same hostId. */
export function socketsToReplace<T>(sockets: readonly HostSocketView<T>[], hostId: string): T[] {
  return sockets.filter((view) => hostIdOf(view.attachment) === hostId).map((view) => view.socket);
}

/** Whether a client gets frames from, and `conn.open` / `conn.close` for, a host (РЛ3). */
export function isBoundTo(client: ClientAttachment | null | undefined, hostId: string): boolean {
  return client != null && boundHostOf(client) === hostId;
}

/** Where a host frame goes (РЛ3, ПР3). */
export type HostFrameRoute =
  | { kind: "rename"; name?: string }
  | { kind: "broadcast" }
  | { kind: "direct"; connId: string }
  | { kind: "drop" };

/**
 * Classifies a parsed host frame. `@` is the control channel: only
 * `{"t":"host.name","name":<string>}` is accepted (a name that normalizes to
 * empty clears it); any other `@` frame is dropped and never forwarded.
 * Direct frames still need `isBoundTo` per recipient.
 */
export function routeHostFrame(connId: string, json: string): HostFrameRoute {
  if (connId === CONTROL_CONN_ID) {
    try {
      const value = JSON.parse(json) as { t?: unknown; name?: unknown };
      if (value && value.t === "host.name" && typeof value.name === "string") {
        return { kind: "rename", name: normalizeHostName(value.name) };
      }
    } catch {
      // Not JSON: dropped.
    }
    return { kind: "drop" };
  }
  if (connId === "*") return { kind: "broadcast" };
  return { kind: "direct", connId };
}

/**
 * Client → host (РЛ3, СВ2): the hostId to forward to, or null when the client
 * gets the `host offline` error (unbound, or its host is offline).
 */
export function clientForwardTarget(client: ClientAttachment | null | undefined, online: ReadonlyMap<string, unknown>): string | null {
  const bound = boundHostOf(client);
  return bound !== null && online.has(bound) ? bound : null;
}

/** Whether a new client is announced with `conn.open` (only to its online bound host, СВ2). */
export function announcesClient(client: ClientAttachment | null | undefined, online: ReadonlyMap<string, unknown>): boolean {
  return clientForwardTarget(client, online) !== null;
}

/** ПР1: the per-client fields of the `relay` message. `host` is omitted for an unbound client. */
export function clientStatus(client: ClientAttachment | null | undefined, hosts: HostInfo[], online: ReadonlyMap<string, unknown>): {
  hostOnline: boolean;
  host?: string;
  hosts: HostInfo[];
} {
  const bound = boundHostOf(client);
  if (bound === null) return { hostOnline: false, hosts };
  return { hostOnline: online.has(bound), host: bound, hosts };
}

/** The entry stored for a host on accept, rename and disconnect, or null for the legacy host (never kept). */
export function knownHostEntry(hostId: string, name: string | undefined, now: number): KnownHost | null {
  if (hostId === LEGACY_HOST_ID) return null;
  return name === undefined ? { lastSeen: now } : { name, lastSeen: now };
}

/**
 * РЛ5 + ПР1: the host list and the stored ids to prune. Online hosts are always
 * listed, never pruned and do not count toward the cap. Offline hosts older than
 * 30 days go, then the oldest beyond 20. The legacy `default` is listed only
 * while online. Sorted by name (case-insensitive, unnamed last), then id.
 */
export function buildHostList(
  known: ReadonlyMap<string, KnownHost>,
  online: ReadonlyMap<string, string | undefined>,
  now: number,
): { hosts: HostInfo[]; prune: string[] } {
  const prune: string[] = [];
  const offline: [string, KnownHost][] = [];
  for (const [id, entry] of known) {
    if (online.has(id)) continue;
    if (id === LEGACY_HOST_ID || now - entry.lastSeen > OFFLINE_RETENTION_MS) {
      prune.push(id);
    } else {
      offline.push([id, entry]);
    }
  }
  offline.sort((a, b) => b[1].lastSeen - a[1].lastSeen);
  for (const [id] of offline.splice(MAX_OFFLINE_HOSTS)) prune.push(id);

  const hosts: HostInfo[] = [];
  // An online host's name is the one its socket carries; the stored one may be older.
  for (const [id, name] of online) hosts.push(hostInfo(id, name, true));
  for (const [id, entry] of offline) hosts.push(hostInfo(id, entry.name, false));
  hosts.sort(compareHosts);
  return { hosts, prune };
}

function hostInfo(id: string, name: string | undefined, online: boolean): HostInfo {
  return name === undefined ? { id, online } : { id, name, online };
}

/** Code-unit order, so Node (tests) and workerd sort the same way. */
function compareHosts(a: HostInfo, b: HostInfo): number {
  if (a.name !== undefined && b.name !== undefined) {
    const left = a.name.toLowerCase();
    const right = b.name.toLowerCase();
    if (left !== right) return left < right ? -1 : 1;
  } else if (a.name !== undefined) {
    return -1;
  } else if (b.name !== undefined) {
    return 1;
  }
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}
