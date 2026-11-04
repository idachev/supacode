import { bearerKey, sha256Hex, timingSafeEqualHex } from "./frames";
import type { GuardDO } from "./guard";
import type { RelayDO } from "./relay";

export { GuardDO } from "./guard";
export { RelayDO } from "./relay";

export interface Env {
  RELAY: DurableObjectNamespace<RelayDO>;
  GUARD: DurableObjectNamespace<GuardDO>;
  /** Connection attempts per client IP: 20 per minute (wrangler.jsonc). */
  CONNECT_LIMIT: RateLimit;
  HOST_KEY_SHA256: string;
  CLIENT_KEY_SHA256: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (path !== "/host" && path !== "/client") return new Response("not found", { status: 404 });

    // The cheap, in-memory limit runs first, so a flood never reaches a
    // Durable Object.
    const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
    const { success } = await env.CONNECT_LIMIT.limit({ key: ip });
    if (!success) return new Response("too many requests", { status: 429 });

    const guard = env.GUARD.get(env.GUARD.idFromName(ip));
    const { blocked, hasFailures } = await guard.check();
    if (blocked) return new Response("blocked", { status: 403 });

    const expected = path === "/host" ? env.HOST_KEY_SHA256 : env.CLIENT_KEY_SHA256;
    const key = bearerKey(request.headers.get("Authorization"));
    if (!expected || !key || !timingSafeEqualHex(await sha256Hex(key), expected)) {
      const nowBlocked = await guard.fail();
      return new Response(nowBlocked ? "blocked" : "unauthorized", { status: nowBlocked ? 403 : 401 });
    }
    if (hasFailures) await guard.succeeded();
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const relay = env.RELAY.get(env.RELAY.idFromName("default"));
    return relay.fetch(request);
  },
} satisfies ExportedHandler<Env>;
