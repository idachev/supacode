import { describe, expect, it } from "vitest";
import { EMPTY_GUARD_STATE, GUARD_POLICY, expiresAt, isBlocked, recordFailure } from "../src/guard-policy";

const minute = 60 * 1000;

describe("failed-key guard", () => {
  it("blocks on the fifth failure inside the window", () => {
    let state = EMPTY_GUARD_STATE;
    for (let i = 0; i < 4; i++) state = recordFailure(state, i * minute);
    expect(isBlocked(state, 4 * minute)).toBe(false);
    state = recordFailure(state, 4 * minute);
    expect(isBlocked(state, 4 * minute)).toBe(true);
    expect(state.blockedUntil).toBe(4 * minute + GUARD_POLICY.blockForMs);
    expect(state.failures).toEqual([]);
  });

  it("forgets failures older than the window", () => {
    let state = EMPTY_GUARD_STATE;
    for (let i = 0; i < 4; i++) state = recordFailure(state, i * minute);
    state = recordFailure(state, 20 * minute);
    expect(isBlocked(state, 20 * minute)).toBe(false);
    expect(state.failures).toEqual([20 * minute]);
  });

  it("unblocks after the block time", () => {
    let state = EMPTY_GUARD_STATE;
    for (let i = 0; i < 5; i++) state = recordFailure(state, 0);
    expect(isBlocked(state, GUARD_POLICY.blockForMs - 1)).toBe(true);
    expect(isBlocked(state, GUARD_POLICY.blockForMs)).toBe(false);
  });

  it("expires after the block and after the last failure's window", () => {
    expect(expiresAt({ failures: [5 * minute], blockedUntil: 0 })).toBe(5 * minute + GUARD_POLICY.windowMs);
    expect(expiresAt({ failures: [], blockedUntil: 99 * minute })).toBe(99 * minute);
  });
});
