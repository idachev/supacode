import { describe, expect, it } from "vitest";
import {
  bearerKey,
  connOpen,
  ipv6Prefix64,
  sameNetwork,
  encodeHostFrame,
  hostOfflineError,
  parseHostFrame,
  requestId,
  sha256Hex,
  timingSafeEqualHex,
} from "../src/frames";

describe("host framing", () => {
  it("splits on the first newline only", () => {
    expect(parseHostFrame('abc\n{"t":"out","b64":"a\\nb"}')).toEqual({
      connId: "abc",
      json: '{"t":"out","b64":"a\\nb"}',
    });
  });

  it("rejects a frame without a prefix", () => {
    expect(parseHostFrame('{"t":"list"}')).toBeNull();
    expect(parseHostFrame('\n{"t":"list"}')).toBeNull();
  });

  it("round-trips", () => {
    const frame = encodeHostFrame("0011", '{"t":"conn.open"}');
    expect(parseHostFrame(frame)).toEqual({ connId: "0011", json: '{"t":"conn.open"}' });
  });
});

describe("errors", () => {
  it("echoes the request id", () => {
    expect(requestId('{"t":"list","id":7}')).toBe(7);
    expect(requestId("not json")).toBeNull();
    expect(JSON.parse(hostOfflineError(7))).toEqual({ t: "error", id: 7, message: "host offline" });
  });
});

describe("auth", () => {
  it("reads a bearer key", () => {
    expect(bearerKey("Bearer abc-def")).toBe("abc-def");
    expect(bearerKey("bearer   abc ")).toBe("abc");
    expect(bearerKey("Basic abc")).toBeNull();
    expect(bearerKey(null)).toBeNull();
  });

  it("hashes and compares", async () => {
    const hash = await sha256Hex("test-key");
    expect(hash).toBe("62af8704764faf8ea82fc61ce9c4c3908b6cb97d463a634e9e587d7c885db0ef");
    expect(timingSafeEqualHex(hash, hash.toUpperCase())).toBe(true);
    expect(timingSafeEqualHex(hash, hash.slice(1))).toBe(false);
    expect(timingSafeEqualHex(hash, "0" + hash.slice(1))).toBe(false);
  });
});

describe("same network hint", () => {
  it("matches equal IPv4 and the same IPv6 /64", () => {
    expect(sameNetwork("203.0.113.7", "203.0.113.7")).toBe(true);
    expect(sameNetwork("203.0.113.7", "203.0.113.8")).toBe(false);
    expect(sameNetwork("2001:db8:1:2::10", "2001:db8:1:2:aaaa::1")).toBe(true);
    expect(sameNetwork("2001:db8:1:2::10", "2001:db8:1:3::10")).toBe(false);
    expect(sameNetwork("203.0.113.7", "2001:db8::1")).toBe(false);
    expect(sameNetwork(null, "203.0.113.7")).toBe(false);
  });

  it("expands IPv6 prefixes", () => {
    expect(ipv6Prefix64("2001:DB8:0001::1")).toBe("2001:db8:1:0");
    expect(ipv6Prefix64("2001:db8:1:2:3:4:5:6")).toBe("2001:db8:1:2");
  });

  it("announces a phone with the hint", () => {
    expect(JSON.parse(connOpen(true))).toEqual({ t: "conn.open", sameNetwork: true });
  });
});
