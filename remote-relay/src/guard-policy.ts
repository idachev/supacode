// Failed-key policy per client IP: `maxFailures` wrong keys within `window`
// block that IP for `blockFor`.
export const GUARD_POLICY = {
  maxFailures: 5,
  windowMs: 10 * 60 * 1000,
  blockForMs: 60 * 60 * 1000,
} as const;

export interface GuardState {
  /** Times of recent failures, inside the window. */
  failures: number[];
  /** Epoch ms until which the IP is blocked; 0 when not blocked. */
  blockedUntil: number;
}

export const EMPTY_GUARD_STATE: GuardState = { failures: [], blockedUntil: 0 };

export function isBlocked(state: GuardState, now: number): boolean {
  return now < state.blockedUntil;
}

/** The state after one more failure at `now`; a block clears the failures. */
export function recordFailure(state: GuardState, now: number, policy = GUARD_POLICY): GuardState {
  const failures = state.failures.filter((at) => now - at < policy.windowMs);
  failures.push(now);
  if (failures.length >= policy.maxFailures) {
    return { failures: [], blockedUntil: now + policy.blockForMs };
  }
  return { failures, blockedUntil: state.blockedUntil };
}

/** When the stored state can be dropped: after the block and the window. */
export function expiresAt(state: GuardState, policy = GUARD_POLICY): number {
  const lastFailure = state.failures.length > 0 ? Math.max(...state.failures) : 0;
  return Math.max(state.blockedUntil, lastFailure + policy.windowMs);
}
