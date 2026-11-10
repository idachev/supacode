import { describe, expect, it } from "vitest";
import { relayStatus } from "../src/frames";
import {
  type ClientAttachment,
  type HostAttachment,
  type HostSocketView,
  type KnownHost,
  LEGACY_HOST_ID,
  MAX_OFFLINE_HOSTS,
  OFFLINE_RETENTION_MS,
  announcesClient,
  boundHostOf,
  buildHostList,
  clientForwardTarget,
  clientStatus,
  hostIdOf,
  isBoundTo,
  isValidHostId,
  knownHostEntry,
  newestHost,
  normalizeHostName,
  onlineHosts,
  parseConnectRequest,
  routeHostFrame,
  socketsToReplace,
} from "../src/hosts";

const view = (socket: string, attachment: HostAttachment | null, open = true): HostSocketView<string> => ({
  socket,
  attachment,
  open,
});

describe("host id and name (РЛ6, ИД4)", () => {
  it("accepts ids of 1 to 64 safe characters", () => {
    expect(isValidHostId("3f9a0c1d2e4b5a69")).toBe(true);
    expect(isValidHostId("default")).toBe(true);
    expect(isValidHostId("A_b-9")).toBe(true);
    expect(isValidHostId("x".repeat(64))).toBe(true);
    expect(isValidHostId("x".repeat(65))).toBe(false);
    expect(isValidHostId("")).toBe(false);
    expect(isValidHostId("a b")).toBe(false);
    expect(isValidHostId("a/b")).toBe(false);
    expect(isValidHostId("мак")).toBe(false);
  });

  it("normalizes names", () => {
    expect(normalizeHostName("  Office Mac \n")).toBe("Office Mac");
    expect(normalizeHostName("a\tb\u0000c")).toBe("a b c");
    expect(normalizeHostName("   ")).toBeUndefined();
    expect(normalizeHostName("")).toBeUndefined();
    expect(normalizeHostName(null)).toBeUndefined();
    expect(normalizeHostName(42)).toBeUndefined();
  });

  it("cuts names to 64 Unicode scalars", () => {
    expect(normalizeHostName("я".repeat(100))).toBe("я".repeat(64));
    const emoji = "😀".repeat(70);
    expect(Array.from(normalizeHostName(emoji)!)).toHaveLength(64);
  });

  it("parses the /host query", () => {
    expect(parseConnectRequest(new URL("wss://relay.example.com/host?id=3f9a&name=Office%20Mac"))).toEqual({
      role: "host",
      hostId: "3f9a",
      name: "Office Mac",
    });
    expect(parseConnectRequest(new URL("wss://relay.example.com/host?id=3f9a&name=%D0%9C%D0%B0%D0%BA%20%E2%80%94%20" + "x".repeat(200)))).toEqual({
      role: "host",
      hostId: "3f9a",
      name: ("Мак — " + "x".repeat(200)).slice(0, 64),
    });
    expect(parseConnectRequest(new URL("wss://relay.example.com/host?id=3f9a&name=%20%20"))).toEqual({ role: "host", hostId: "3f9a", name: undefined });
  });

  it("files a host without id as the legacy host with no name (СВ1)", () => {
    expect(parseConnectRequest(new URL("wss://relay.example.com/host"))).toEqual({ role: "host", hostId: LEGACY_HOST_ID });
    expect(parseConnectRequest(new URL("wss://relay.example.com/host?name=Mac"))).toEqual({ role: "host", hostId: LEGACY_HOST_ID });
  });

  it("rejects a present but invalid id, never a name", () => {
    expect(parseConnectRequest(new URL("wss://relay.example.com/host?id="))).toBeNull();
    expect(parseConnectRequest(new URL("wss://relay.example.com/host?id=a%20b"))).toBeNull();
    expect(parseConnectRequest(new URL("wss://relay.example.com/client?host="))).toBeNull();
    expect(parseConnectRequest(new URL("wss://relay.example.com/client?host=" + "x".repeat(65)))).toBeNull();
    expect(parseConnectRequest(new URL("wss://relay.example.com/host?id=ok&name=%00%01"))).not.toBeNull();
  });

  it("parses the /client query", () => {
    expect(parseConnectRequest(new URL("wss://relay.example.com/client?host=3f9a"))).toEqual({ role: "client", hostId: "3f9a" });
    expect(parseConnectRequest(new URL("wss://relay.example.com/client"))).toEqual({ role: "client", hostId: null });
  });
});

describe("attachments from before the deploy (РЛ1)", () => {
  it("counts a host without hostId as default", () => {
    expect(hostIdOf({ generation: 1, ip: "203.0.113.7" })).toBe(LEGACY_HOST_ID);
    expect(hostIdOf(null)).toBe(LEGACY_HOST_ID);
    expect(hostIdOf({ generation: 1, hostId: "abc" })).toBe("abc");
    const online = onlineHosts([view("old", { generation: 1, ip: null })]);
    expect([...online]).toEqual([[LEGACY_HOST_ID, undefined]]);
  });

  it("counts a client without hostId as unbound", () => {
    const old: ClientAttachment = { connId: "00112233aabbccdd", ip: null };
    expect(boundHostOf(old)).toBeNull();
    expect(isBoundTo(old, LEGACY_HOST_ID)).toBe(false);
    expect(clientForwardTarget(old, new Map([[LEGACY_HOST_ID, undefined]]))).toBeNull();
  });
});

describe("unbound client (СВ2)", () => {
  const unbound: ClientAttachment = { connId: "c1", ip: null, hostId: null };
  const online = new Map<string, string | undefined>([["mac1", "Office"]]);
  const hosts = buildHostList(new Map(), online, 0).hosts;

  it("gets the list without host and hostOnline false", () => {
    const status = clientStatus(unbound, hosts, online);
    expect(JSON.parse(relayStatus(status.hostOnline, status))).toEqual({
      t: "relay",
      hostOnline: false,
      hosts: [{ id: "mac1", name: "Office", online: true }],
    });
  });

  it("is announced to no host and gets host offline", () => {
    expect(announcesClient(unbound, online)).toBe(false);
    expect(clientForwardTarget(unbound, online)).toBeNull();
    expect(isBoundTo(unbound, "mac1")).toBe(false);
  });
});

describe("bound client (РЛ3, РЛ4)", () => {
  const client: ClientAttachment = { connId: "c1", ip: null, hostId: "mac1" };

  it("is announced to and forwards to its host only while it is online", () => {
    expect(announcesClient(client, new Map([["mac1", undefined]]))).toBe(true);
    expect(clientForwardTarget(client, new Map([["mac1", undefined]]))).toBe("mac1");
    expect(announcesClient(client, new Map([["mac2", undefined]]))).toBe(false);
    expect(clientForwardTarget(client, new Map([["mac2", undefined]]))).toBeNull();
  });

  it("binds to an unknown host and sees it offline", () => {
    const status = clientStatus({ connId: "c2", hostId: "gone" }, [], new Map());
    expect(JSON.parse(relayStatus(status.hostOnline, status))).toEqual({ t: "relay", hostOnline: false, host: "gone", hosts: [] });
  });
});

describe("host frame recipients (РЛ3, ПР3)", () => {
  const mac1: ClientAttachment = { connId: "c1", hostId: "mac1" };
  const mac2: ClientAttachment = { connId: "c2", hostId: "mac2" };
  const unbound: ClientAttachment = { connId: "c3", hostId: null };

  it("delivers a direct frame only to a client bound to the sender", () => {
    expect(routeHostFrame("c1", '{"t":"out"}')).toEqual({ kind: "direct", connId: "c1" });
    expect(isBoundTo(mac1, "mac1")).toBe(true);
    expect(isBoundTo(mac2, "mac1")).toBe(false);
    expect(isBoundTo(unbound, "mac1")).toBe(false);
    expect(isBoundTo(null, "mac1")).toBe(false);
  });

  it("broadcasts * only to the sender's clients", () => {
    expect(routeHostFrame("*", '{"t":"tick"}')).toEqual({ kind: "broadcast" });
    expect([mac1, mac2, unbound].filter((c) => isBoundTo(c, "mac2"))).toEqual([mac2]);
  });

  it("handles a rename on @ and drops any other @ frame", () => {
    expect(routeHostFrame("@", '{"t":"host.name","name":"  New\\nName "}')).toEqual({ kind: "rename", name: "New Name" });
    expect(routeHostFrame("@", '{"t":"host.name","name":"   "}')).toEqual({ kind: "rename", name: undefined });
    expect(routeHostFrame("@", '{"t":"host.name"}')).toEqual({ kind: "drop" });
    expect(routeHostFrame("@", '{"t":"host.name","name":5}')).toEqual({ kind: "drop" });
    expect(routeHostFrame("@", '{"t":"other"}')).toEqual({ kind: "drop" });
    expect(routeHostFrame("@", "not json")).toEqual({ kind: "drop" });
    expect(routeHostFrame("@", "null")).toEqual({ kind: "drop" });
  });
});

describe("host slots (РЛ2, РЛ3)", () => {
  const sockets = [
    view("a-old", { generation: 1, hostId: "mac1", name: "Old" }),
    view("a-new", { generation: 2, hostId: "mac1", name: "New" }),
    view("b", { generation: 3, hostId: "mac2" }),
    view("legacy", { generation: 4 }),
    view("c-closed", { generation: 5, hostId: "mac3" }, false),
  ];

  it("replaces only sockets with the same hostId", () => {
    expect(socketsToReplace(sockets, "mac1")).toEqual(["a-old", "a-new"]);
    expect(socketsToReplace(sockets, "mac2")).toEqual(["b"]);
    expect(socketsToReplace(sockets, LEGACY_HOST_ID)).toEqual(["legacy"]);
    expect(socketsToReplace(sockets, "mac9")).toEqual([]);
  });

  it("routes to the newest open socket of the hostId", () => {
    expect(newestHost(sockets, "mac1")?.socket).toBe("a-new");
    expect(newestHost(sockets, "mac1", "a-new")?.socket).toBe("a-old");
    expect(newestHost(sockets, "mac3")).toBeNull();
  });

  it("lists online hosts with the newest socket's name, skipping a closing one", () => {
    expect(onlineHosts(sockets)).toEqual(
      new Map<string, string | undefined>([
        ["mac1", "New"],
        ["mac2", undefined],
        [LEGACY_HOST_ID, undefined],
      ]),
    );
    expect(onlineHosts(sockets, "b").has("mac2")).toBe(false);
  });
});

describe("relay message (ПР1)", () => {
  it("sorts by name case-insensitively, unnamed last, then id; omits unknown names", () => {
    const online = new Map<string, string | undefined>([
      ["z1", "beta"],
      ["a1", undefined],
      [LEGACY_HOST_ID, undefined],
    ]);
    const known = new Map<string, KnownHost>([
      ["b2", { name: "Alpha", lastSeen: 100 }],
      ["c3", { name: "alpha", lastSeen: 100 }],
      ["d4", { lastSeen: 100 }],
    ]);
    const { hosts } = buildHostList(known, online, 200);
    expect(hosts).toEqual([
      { id: "b2", name: "Alpha", online: false },
      { id: "c3", name: "alpha", online: false },
      { id: "z1", name: "beta", online: true },
      { id: "a1", online: true },
      { id: "d4", online: false },
      { id: LEGACY_HOST_ID, online: true },
    ]);
  });

  it("gives each client its own host and hostOnline", () => {
    const online = new Map<string, string | undefined>([["mac1", "Office"]]);
    const { hosts } = buildHostList(new Map([["mac2", { name: "Home", lastSeen: 1 }]]), online, 2);
    const one = clientStatus({ connId: "c1", hostId: "mac1" }, hosts, online);
    const two = clientStatus({ connId: "c2", hostId: "mac2" }, hosts, online);
    expect(JSON.parse(relayStatus(one.hostOnline, one))).toEqual({
      t: "relay",
      hostOnline: true,
      host: "mac1",
      hosts: [
        { id: "mac2", name: "Home", online: false },
        { id: "mac1", name: "Office", online: true },
      ],
    });
    expect(JSON.parse(relayStatus(two.hostOnline, two))).toMatchObject({ hostOnline: false, host: "mac2" });
  });

  it("keeps the old shape when no extras are given", () => {
    expect(JSON.parse(relayStatus(true))).toEqual({ t: "relay", hostOnline: true });
  });
});

describe("known hosts (РЛ5)", () => {
  const now = 1_000 * OFFLINE_RETENTION_MS;
  const day = 24 * 60 * 60 * 1000;

  it("prunes offline hosts not seen for 30 days", () => {
    const known = new Map<string, KnownHost>([
      ["fresh", { name: "Fresh", lastSeen: now - 29 * day }],
      ["stale", { name: "Stale", lastSeen: now - 31 * day }],
    ]);
    const { hosts, prune } = buildHostList(known, new Map(), now);
    expect(hosts.map((h) => h.id)).toEqual(["fresh"]);
    expect(prune).toEqual(["stale"]);
  });

  it("keeps at most 20 offline hosts, the oldest go first", () => {
    const known = new Map<string, KnownHost>();
    for (let i = 0; i < MAX_OFFLINE_HOSTS + 3; i++) known.set(`h${String(i).padStart(2, "0")}`, { lastSeen: now - i * 1000 });
    const { hosts, prune } = buildHostList(known, new Map(), now);
    expect(hosts).toHaveLength(MAX_OFFLINE_HOSTS);
    expect(prune.sort()).toEqual(["h20", "h21", "h22"]);
  });

  it("never prunes an online host and does not count it toward the cap", () => {
    const known = new Map<string, KnownHost>([["long-online", { name: "Old", lastSeen: now - 365 * day }]]);
    for (let i = 0; i < MAX_OFFLINE_HOSTS; i++) known.set(`h${String(i).padStart(2, "0")}`, { lastSeen: now - i * 1000 });
    const online = new Map<string, string | undefined>([["long-online", "Old"]]);
    const { hosts, prune } = buildHostList(known, online, now);
    expect(prune).toEqual([]);
    expect(hosts).toHaveLength(MAX_OFFLINE_HOSTS + 1);
    expect(hosts.find((h) => h.id === "long-online")).toEqual({ id: "long-online", name: "Old", online: true });
  });

  it("lists the legacy host only while online and never stores it", () => {
    expect(knownHostEntry(LEGACY_HOST_ID, undefined, now)).toBeNull();
    expect(knownHostEntry("mac1", "Office", now)).toEqual({ name: "Office", lastSeen: now });
    expect(knownHostEntry("mac1", undefined, now)).toEqual({ lastSeen: now });
    const known = new Map<string, KnownHost>([[LEGACY_HOST_ID, { lastSeen: now }]]);
    expect(buildHostList(known, new Map(), now)).toEqual({ hosts: [], prune: [LEGACY_HOST_ID] });
    expect(buildHostList(new Map(), new Map([[LEGACY_HOST_ID, undefined]]), now).hosts).toEqual([{ id: LEGACY_HOST_ID, online: true }]);
  });
});
