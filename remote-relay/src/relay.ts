import { DurableObject } from "cloudflare:workers";
import {
  connOpen,
  encodeHostFrame,
  hostOfflineError,
  parseHostFrame,
  randomConnId,
  sameNetwork,
  relayStatus,
  requestId,
} from "./frames";
import {
  KNOWN_HOST_PREFIX,
  type ClientAttachment,
  type HostAttachment,
  type HostInfo,
  type HostSocketView,
  type KnownHost,
  boundHostOf,
  buildHostList,
  clientForwardTarget,
  clientStatus,
  hostIdOf,
  isBoundTo,
  knownHostEntry,
  newestHost,
  onlineHosts,
  parseConnectRequest,
  pruneKeyBatches,
  routeHostFrame,
  socketsToReplace,
} from "./hosts";

export interface Env {
  RELAY: DurableObjectNamespace<RelayDO>;
  HOST_KEY_SHA256: string;
  CLIENT_KEY_SHA256: string;
}

const HOST_TAG = "host";
// WebSocket.readyState OPEN; a literal so hibernated sockets need no global lookup.
const OPEN_STATE = 1;
const CLIENT_TAG = "client";
const clientTag = (connId: string) => `c:${connId}`;

/**
 * One instance routes every frame between the Supacode host sockets (one slot
 * per hostId) and the phone sockets, each bound to one hostId for its life. It
 * never parses application messages beyond the `<connId>\n` prefix (see
 * docs/remote-access-protocol.md, "Relay framing"); the routing decisions live
 * in `hosts.ts`.
 */
export class RelayDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Keepalives are answered without waking a hibernated object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    // The Worker already rejected a bad id with 400; this is the same parse.
    const parsed = parseConnectRequest(new URL(request.url));
    if (!parsed) return new Response("bad host id", { status: 400 });
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    const ip = request.headers.get("CF-Connecting-IP");
    if (parsed.role === "host") {
      await this.acceptHost(server, ip, parsed.hostId, parsed.name);
    } else {
      await this.acceptClient(server, ip, parsed.hostId);
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  private async acceptHost(socket: WebSocket, ip: string | null, hostId: string, name: string | undefined) {
    const previous = socketsToReplace(this.hostViews(), hostId);
    this.ctx.acceptWebSocket(socket, [HOST_TAG]);
    socket.serializeAttachment({ generation: Date.now(), ip, hostId, name } satisfies HostAttachment);
    for (const old of previous) {
      // The text notice tells the old host to stop instead of reconnecting and
      // replacing this one in turn (two Supacode instances would flap).
      this.safeSend(old, "replaced");
      try {
        old.close(4000, "replaced");
      } catch {
        // Already closing.
      }
    }
    await this.remember(hostId, name);
    const { hosts, online } = await this.hostList();
    const clients = this.clientViews();
    // The host forgets every attachment when it reconnects, so a phone bound
    // to it must see a false -> true edge to re-attach, even when the old
    // socket is still listed as open. Phones bound to other hosts see nothing.
    if (previous.length > 0) {
      for (const { socket: phone, attachment } of clients) {
        if (isBoundTo(attachment, hostId)) this.safeSend(phone, relayStatus(false, { host: hostId, hosts }));
      }
    }
    for (const { attachment } of clients) {
      if (attachment && isBoundTo(attachment, hostId)) {
        this.safeSend(socket, encodeHostFrame(attachment.connId, connOpen(sameNetwork(ip, attachment.ip ?? null))));
      }
    }
    this.sendStatusToClients(hosts, online);
  }

  private async acceptClient(socket: WebSocket, ip: string | null, hostId: string | null) {
    const connId = randomConnId();
    const attachment: ClientAttachment = { connId, ip, hostId };
    this.ctx.acceptWebSocket(socket, [CLIENT_TAG, clientTag(connId)]);
    socket.serializeAttachment(attachment);
    const { hosts, online, pruned } = await this.hostList();
    if (pruned) {
      // The list shrank for everyone, this client included.
      this.sendStatusToClients(hosts, online);
    } else {
      this.safeSend(socket, statusFor(attachment, hosts, online));
    }
    // An unbound client, or one bound to an offline host, is announced nowhere (СВ2).
    const target = clientForwardTarget(attachment, online);
    const host = target === null ? null : newestHost(this.hostViews(), target);
    if (host) {
      this.safeSend(host.socket, encodeHostFrame(connId, connOpen(sameNetwork(ip, host.attachment?.ip ?? null))));
    }
  }

  async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer) {
    if (typeof message !== "string") return;
    if (this.ctx.getTags(socket).includes(HOST_TAG)) {
      await this.routeFromHost(socket, message);
    } else {
      this.routeFromClient(socket, message);
    }
  }

  async webSocketClose(socket: WebSocket, code: number, reason: string) {
    await this.handleGone(socket);
    try {
      socket.close(code === 1005 ? 1000 : code, reason);
    } catch {
      // Already closed.
    }
  }

  async webSocketError(socket: WebSocket) {
    await this.handleGone(socket);
  }

  private async handleGone(socket: WebSocket) {
    if (this.ctx.getTags(socket).includes(HOST_TAG)) {
      const attachment = socket.deserializeAttachment() as HostAttachment | null;
      const hostId = hostIdOf(attachment);
      // Only the last socket of a hostId going away takes that Mac offline; a
      // replaced one closing later changes nothing.
      if (newestHost(this.hostViews(), hostId, socket) !== null) return;
      await this.remember(hostId, attachment?.name);
      const { hosts, online } = await this.hostList(socket);
      this.sendStatusToClients(hosts, online);
      return;
    }
    const attachment = socket.deserializeAttachment() as ClientAttachment | null;
    const host = this.boundHost(attachment);
    if (attachment && host) this.safeSend(host.socket, encodeHostFrame(attachment.connId, '{"t":"conn.close"}'));
  }

  private async routeFromHost(socket: WebSocket, message: string) {
    const frame = parseHostFrame(message);
    if (!frame) return;
    const attachment = socket.deserializeAttachment() as HostAttachment | null;
    const hostId = hostIdOf(attachment);
    const route = routeHostFrame(frame.connId, frame.json);
    switch (route.kind) {
      case "rename": {
        // ИД3: the only frame that writes storage; never forwarded.
        socket.serializeAttachment({ ...(attachment ?? { generation: 0 }), hostId, name: route.name } satisfies HostAttachment);
        await this.remember(hostId, route.name);
        const { hosts, online } = await this.hostList();
        this.sendStatusToClients(hosts, online);
        return;
      }
      case "broadcast":
        for (const { socket: phone, attachment: client } of this.clientViews()) {
          if (isBoundTo(client, hostId)) this.safeSend(phone, frame.json);
        }
        return;
      case "direct":
        for (const phone of this.ctx.getWebSockets(clientTag(route.connId))) {
          // A frame for a phone bound to another Mac is dropped.
          if (isBoundTo(phone.deserializeAttachment() as ClientAttachment | null, hostId)) this.safeSend(phone, frame.json);
        }
        return;
      case "drop":
        return;
    }
  }

  private routeFromClient(socket: WebSocket, message: string) {
    const attachment = socket.deserializeAttachment() as ClientAttachment | null;
    if (!attachment) return;
    // Unbound, or the bound host is offline: the usual error (РЛ3, СВ2).
    const host = this.boundHost(attachment);
    if (!host) {
      this.safeSend(socket, hostOfflineError(requestId(message)));
      return;
    }
    this.safeSend(host.socket, encodeHostFrame(attachment.connId, message));
  }

  /** The newest open socket of the client's bound host; null when unbound or offline. */
  private boundHost(client: ClientAttachment | null): HostSocketView<WebSocket> | null {
    const bound = boundHostOf(client);
    return bound === null ? null : newestHost(this.hostViews(), bound);
  }

  /** Stores `host:<hostId>` on host accept, rename and disconnect (РЛ5); never the legacy host. */
  private async remember(hostId: string, name: string | undefined) {
    const entry = knownHostEntry(hostId, name, Date.now());
    if (entry) await this.ctx.storage.put(KNOWN_HOST_PREFIX + hostId, entry);
  }

  /** The current host list; prunes stored hosts that aged out (РЛ5). `except` is a host socket that is closing. */
  private async hostList(except?: WebSocket): Promise<{ hosts: HostInfo[]; online: Map<string, string | undefined>; pruned: boolean }> {
    const stored = await this.ctx.storage.list<KnownHost>({ prefix: KNOWN_HOST_PREFIX });
    const known = new Map<string, KnownHost>();
    for (const [key, entry] of stored) known.set(key.slice(KNOWN_HOST_PREFIX.length), entry);
    const online = onlineHosts(this.hostViews(), except);
    const { hosts, prune } = buildHostList(known, online, Date.now());
    for (const keys of pruneKeyBatches(prune)) await this.ctx.storage.delete(keys);
    return { hosts, online, pruned: prune.length > 0 };
  }

  /** ПР1: each client gets its own copy, with its own `host` and `hostOnline`. */
  private sendStatusToClients(hosts: HostInfo[], online: ReadonlyMap<string, unknown>) {
    for (const { socket, attachment } of this.clientViews()) {
      this.safeSend(socket, statusFor(attachment, hosts, online));
    }
  }

  private hostViews(): HostSocketView<WebSocket>[] {
    return this.ctx.getWebSockets(HOST_TAG).map((socket) => ({
      socket,
      attachment: socket.deserializeAttachment() as HostAttachment | null,
      open: socket.readyState === OPEN_STATE,
    }));
  }

  private clientViews(): { socket: WebSocket; attachment: ClientAttachment | null }[] {
    return this.ctx.getWebSockets(CLIENT_TAG).map((socket) => ({
      socket,
      attachment: socket.deserializeAttachment() as ClientAttachment | null,
    }));
  }

  private safeSend(socket: WebSocket, text: string) {
    try {
      socket.send(text);
    } catch {
      // The peer is closing; its close handler cleans up.
    }
  }
}

function statusFor(client: ClientAttachment | null, hosts: HostInfo[], online: ReadonlyMap<string, unknown>): string {
  const status = clientStatus(client, hosts, online);
  return relayStatus(status.hostOnline, status);
}
