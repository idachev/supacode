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

interface ClientAttachment {
  connId: string;
  /** CF-Connecting-IP, for the same-network hint. */
  ip?: string | null;
}

interface HostAttachment {
  /** Accept time; the highest one is the current host. */
  generation: number;
  ip?: string | null;
}

/**
 * One instance routes every frame between the single Supacode host socket and
 * the phone sockets. It never parses application messages beyond the
 * `<connId>\n` prefix (see docs/remote-access-protocol.md, "Relay framing").
 */
export class RelayDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Keepalives are answered without waking a hibernated object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    const role = new URL(request.url).pathname === "/host" ? HOST_TAG : CLIENT_TAG;
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    const ip = request.headers.get("CF-Connecting-IP");
    if (role === HOST_TAG) {
      this.acceptHost(server, ip);
    } else {
      this.acceptClient(server, ip);
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  private acceptHost(socket: WebSocket, ip: string | null) {
    const previous = this.ctx.getWebSockets(HOST_TAG);
    const generation = Date.now();
    this.ctx.acceptWebSocket(socket, [HOST_TAG]);
    socket.serializeAttachment({ generation, ip } satisfies HostAttachment);
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
    // The host forgets every attachment when it reconnects, so a phone must
    // see a false -> true edge to re-attach, even when the old socket is
    // still listed as open.
    if (previous.length > 0) this.broadcastToClients(relayStatus(false));
    for (const phone of this.ctx.getWebSockets(CLIENT_TAG)) {
      const attachment = phone.deserializeAttachment() as ClientAttachment | null;
      if (attachment) {
        this.safeSend(socket, encodeHostFrame(attachment.connId, connOpen(sameNetwork(ip, attachment.ip ?? null))));
      }
    }
    this.broadcastToClients(relayStatus(true));
  }

  private acceptClient(socket: WebSocket, ip: string | null) {
    const connId = randomConnId();
    this.ctx.acceptWebSocket(socket, [CLIENT_TAG, clientTag(connId)]);
    socket.serializeAttachment({ connId, ip } satisfies ClientAttachment);
    const host = this.host();
    this.safeSend(socket, relayStatus(host !== null));
    if (host) {
      const hostIP = (host.deserializeAttachment() as HostAttachment | null)?.ip ?? null;
      this.safeSend(host, encodeHostFrame(connId, connOpen(sameNetwork(ip, hostIP))));
    }
  }

  async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer) {
    if (typeof message !== "string") return;
    if (this.ctx.getTags(socket).includes(HOST_TAG)) {
      this.routeFromHost(message);
    } else {
      this.routeFromClient(socket, message);
    }
  }

  async webSocketClose(socket: WebSocket, code: number, reason: string) {
    this.handleGone(socket);
    try {
      socket.close(code === 1005 ? 1000 : code, reason);
    } catch {
      // Already closed.
    }
  }

  async webSocketError(socket: WebSocket) {
    this.handleGone(socket);
  }

  private handleGone(socket: WebSocket) {
    const tags = this.ctx.getTags(socket);
    if (tags.includes(HOST_TAG)) {
      // Only the current host going away takes the Mac offline; a replaced
      // one closing later changes nothing.
      const current = this.host();
      if (current === null || current === socket) {
        if (this.host(socket) === null) this.broadcastToClients(relayStatus(false));
      }
      return;
    }
    const attachment = socket.deserializeAttachment() as ClientAttachment | null;
    const host = this.host();
    if (attachment && host) this.safeSend(host, encodeHostFrame(attachment.connId, '{"t":"conn.close"}'));
  }

  private routeFromHost(message: string) {
    const frame = parseHostFrame(message);
    if (!frame) return;
    if (frame.connId === "*") {
      this.broadcastToClients(frame.json);
      return;
    }
    for (const phone of this.ctx.getWebSockets(clientTag(frame.connId))) {
      this.safeSend(phone, frame.json);
    }
  }

  private routeFromClient(socket: WebSocket, message: string) {
    const attachment = socket.deserializeAttachment() as ClientAttachment | null;
    if (!attachment) return;
    const host = this.host();
    if (!host) {
      this.safeSend(socket, hostOfflineError(requestId(message)));
      return;
    }
    this.safeSend(host, encodeHostFrame(attachment.connId, message));
  }

  /** The newest host socket; a replaced one may still be listed while it closes. */
  private host(except?: WebSocket): WebSocket | null {
    let newest: WebSocket | null = null;
    let newestGeneration = -1;
    for (const socket of this.ctx.getWebSockets(HOST_TAG)) {
      if (socket === except || socket.readyState !== OPEN_STATE) continue;
      const generation = (socket.deserializeAttachment() as HostAttachment | null)?.generation ?? 0;
      if (generation > newestGeneration) {
        newest = socket;
        newestGeneration = generation;
      }
    }
    return newest;
  }

  private broadcastToClients(text: string) {
    for (const phone of this.ctx.getWebSockets(CLIENT_TAG)) this.safeSend(phone, text);
  }

  private safeSend(socket: WebSocket, text: string) {
    try {
      socket.send(text);
    } catch {
      // The peer is closing; its close handler cleans up.
    }
  }
}
