import { DurableObject } from "cloudflare:workers";
import { EMPTY_GUARD_STATE, type GuardState, expiresAt, isBlocked, recordFailure } from "./guard-policy";

/** One instance per client IP (`idFromName(ip)`); deletes itself when idle. */
export class GuardDO extends DurableObject {
  private async load(): Promise<GuardState> {
    return (await this.ctx.storage.get<GuardState>("state")) ?? EMPTY_GUARD_STATE;
  }

  /** Whether the IP is blocked, and whether it has failures to clear on success. */
  async check(): Promise<{ blocked: boolean; hasFailures: boolean }> {
    const state = await this.load();
    return { blocked: isBlocked(state, Date.now()), hasFailures: state.failures.length > 0 };
  }

  /** A correct key: earlier typos no longer count toward a block. */
  async succeeded(): Promise<void> {
    await this.ctx.storage.deleteAll();
  }

  /** Records a wrong key; returns true when the IP is now blocked. */
  async fail(): Promise<boolean> {
    const now = Date.now();
    const next = recordFailure(await this.load(), now);
    await this.ctx.storage.put("state", next);
    await this.ctx.storage.setAlarm(expiresAt(next));
    return isBlocked(next, now);
  }

  async alarm(): Promise<void> {
    const state = await this.load();
    if (Date.now() >= expiresAt(state)) {
      await this.ctx.storage.deleteAll();
    } else {
      await this.ctx.storage.setAlarm(expiresAt(state));
    }
  }
}
