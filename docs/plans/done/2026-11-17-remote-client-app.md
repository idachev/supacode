# Remote Client — The Client In Supacode (ЕТ2–ЕТ5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A second window in Supacode shows another Mac's Supacode: its sidebar, its tabs and
splits as real Ghostty terminals, the layout actions, a "no connection" banner and "agent is
waiting" notifications.

**Architecture:** A Swift client of the remote access protocol lives in
`supacode/Features/RemoteClient/`: pure rule types first, then one `RemoteClientConnection` that owns
the relay and LAN sockets. A remote tab is a normal Ghostty surface whose process is the bundled
CLI's `remote-pipe`, a byte pipe to the app over a unix socket. A TCA feature, `RemoteClientFeature`,
drives a new `Window` scene; no remote state enters `RepositoriesFeature` or `TerminalsFeature`.

**Tech Stack:** Swift 6, TCA, Network.framework, GhosttyKit, swift-argument-parser (CLI), Swift
Testing with `TestClock`.

**Spec:** `docs/plans/done/2026-11-17-remote-client-design.md` ("Client design", "No connection",
"Notifications"). **Depends on:** `docs/plans/done/2026-11-17-remote-client-host.md` finished through its
Task 10 (a host that sends `caps`, `layout`, pushed `list`, and answers `keep`, `hold` and the
layout actions; `GhosttySurfaceView.pinGrid` exists).

## Global Constraints

- New code goes in `supacode/Features/RemoteClient/`; the CLI command in `supacode-cli/Commands/`.
  Upstream files change as little as possible; every changed upstream file is listed in
  `docs/fork.md` at the end.
- Remote ids, repositories and layouts never enter `RepositoriesFeature`, `TerminalsFeature`,
  `LayoutFeature`, `routes.json`, `layoutsFile` or `sidebarState`. No new `LayoutFeature` state or
  actions. No `ContentKind` case is added.
- The key and the relay address come only from `~/.config/supacode/remote-client-key.txt`. They, and
  every Mac's name, never reach a log line. Logging goes through `SupaLogger`.
- The client never sends `resize` in answer to a `size` it did not ask for; it sends `resize` (always
  with `hold:true`) only after its own `attached` and 200 ms after its pane's grid settled.
- Nothing is sent to the host before the relay says `hostOnline:true`; `hello`, `list`, `watch` and
  the attaches go out only on a `hostOnline` false → true edge.
- `@ObservableState` for the feature, `@MainActor @Observable` for shared stores, every main-actor
  class with `nonisolated deinit {}`, no top-level free functions, no `Task.sleep` in tests (inject
  a clock), menu actions through `FocusedAction`, buttons with a tooltip that names the hotkey,
  system colors and Dynamic Type only.
- Commits: one per task, only the task's files, no co-author line; swift-format the task's files
  first. Test and build commands and the log rule are those of the host plan ("Run one suite").
  New suites `RemoteClient*Tests` land in the `supacodeTests` target.

## Review Focus

- **РФ1.** A terminal query split across two `out` frames (for example `ESC [` in one, `c` in the
  next) is dropped whole, and a broken sequence longer than 4096 bytes is let through, not held
  forever. Pinned in Task 2.
- **РФ2.** A `list` with a `status`, `activity` or section `kind` this build does not know, or
  without `layout`, still decodes; the rest of the list is shown. Pinned in Task 1.
- **РФ3.** The relay repeats `hostOnline:true` (a host list update): the client sends no second
  `hello`, and attached terminals are not re-attached. Pinned in Task 6.
- **РФ4.** A LAN ⇄ relay switch while two tabs are attached: no frame of the old path reaches a
  terminal after the new `attached`, and `detach` on the old path goes out only after the `resize`
  with `hold` on the new one. Pinned in Tasks 3 and 6.
- **РФ5.** The owner types while there is no connection: nothing is sent later, and nothing is
  queued. Pinned in Task 13.

---

## Stage ЕТ2 — the client core (no UI)

### Task 1: The key file and the client's protocol models

**Files:**
- Create: `supacode/Features/RemoteClient/RemoteClientKey.swift`
- Create: `supacode/Features/RemoteClient/RemoteClientModels.swift`
- Test: `supacodeTests/RemoteClientModelsTests.swift`

**Interfaces:**
- Produces:

```swift
nonisolated struct RemoteClientKey: Equatable, Sendable {
  let relayHost: String        // "relay.example.com", or with "http://" / "https://" in front
  let key: String
  /// The text of remote-client-key.txt: "<relay host>/<client key>". nil without a host or a key.
  static func parse(_ text: String) -> RemoteClientKey?
  static func load(from url: URL = RemoteAccessConfig.clientKeyFileURL) -> RemoteClientKey?
  /// wss://<host>/client[?host=<id>]; "http://" in the file gives ws://.
  func clientURL(hostID: String?) -> URL?
}

nonisolated struct RemoteClientHostInfo: Decodable, Equatable, Sendable, Identifiable { let id: String; var name: String?; var online = false }
nonisolated struct RemoteClientAgent: Decodable, Equatable, Sendable { var agent = ""; var activity = "" }
nonisolated struct RemoteClientTab: Decodable, Equatable, Sendable, Identifiable {
  let id: String; var contentId = ""; var title = ""; var focused = false; var working = false
  var readOnly = false; var agents: [RemoteClientAgent] = []
}
nonisolated indirect enum RemoteClientLayoutNode: Decodable, Equatable, Sendable {
  case pane(String)
  case split(direction: String, ratio: Double, left: RemoteClientLayoutNode, right: RemoteClientLayoutNode)
}
nonisolated struct RemoteClientLayoutGroup: Decodable, Equatable, Sendable, Identifiable {
  let id: String; var focusedPaneId: String?; var zoomedPaneId: String?; let tree: RemoteClientLayoutNode
}
nonisolated struct RemoteClientLayoutPane: Decodable, Equatable, Sendable, Identifiable {
  let id: String; var tabIds: [String] = []; var selectedTabId: String?
}
nonisolated struct RemoteClientLayout: Decodable, Equatable, Sendable {
  var mode = "tabsPerSplit"; var activeGroupId = ""; var groups: [RemoteClientLayoutGroup] = []
  var panes: [RemoteClientLayoutPane] = []
}
nonisolated struct RemoteClientWorktree: Decodable, Equatable, Sendable, Identifiable {
  let id: String; var name = ""; var branch = ""; var status = ""; var focused = false
  var title: String?; var working = false; var canDeleteWorktree = false
  var tabs: [RemoteClientTab] = []; var layout: RemoteClientLayout?
}
nonisolated struct RemoteClientRepository: Decodable, Equatable, Sendable, Identifiable {
  let id: String; var name = ""; var group: String?; var canCreateWorktree = false
  var worktrees: [RemoteClientWorktree] = []; var rowIds: [String] = []
}
nonisolated struct RemoteClientSection: Decodable, Equatable, Sendable {
  var kind = ""; var title: String?; var collapsed: Bool?
  var worktreeIds: [String]?; var repositoryIds: [String]?; var repositoryId: String?
}
nonisolated struct RemoteClientLoadFailure: Decodable, Equatable, Sendable { var repositoryId = ""; var message = "" }
nonisolated struct RemoteClientList: Decodable, Equatable, Sendable {
  var id: Int?; var repos: [RemoteClientRepository] = []; var sections: [RemoteClientSection] = []
  var canRefreshWorktrees = false; var loadFailures: [RemoteClientLoadFailure] = []
}
nonisolated struct RemoteClientLAN: Decodable, Equatable, Sendable { var addrs: [String] = []; var port = 0; var fp = ""; var fpMac = "" }
nonisolated struct RemoteClientHello: Decodable, Equatable, Sendable {
  var v = 0; var host: String?; var hostId: String?; var lan: RemoteClientLAN?; var app: String?; var caps: [String] = []
}
nonisolated struct RemoteClientRelayStatus: Decodable, Equatable, Sendable {
  var hostOnline = false; var host: String?; var hosts: [RemoteClientHostInfo]?   // nil: an old relay
}
/// One decoded frame from the host or the relay.
nonisolated enum RemoteClientFrame: Equatable, Sendable {
  case relay(RemoteClientRelayStatus)
  case hello(RemoteClientHello)
  case list(RemoteClientList)
  case attached(id: Int?, contentId: String, cols: Int, rows: Int)
  case out(contentId: String, bytes: [UInt8])
  case size(contentId: String, cols: Int, rows: Int)
  case detached(contentId: String, reason: String)
  case error(id: Int?, message: String, code: String?, contentId: String?)
  /// Any other reply with a `t` (tab.new, pane.split, watch, worktree.new, …): its fields as strings.
  case reply(t: String, id: Int?, fields: [String: String])
  static func decode(_ text: String) -> RemoteClientFrame?     // nil: not JSON, no `t`, or "pong"
}
```

Every struct decodes with a hand-written `init(from:)` that uses `decodeIfPresent` and the default
above for each field, so a missing or `null` field never throws; only a missing `id` on an
identified type does.

- [ ] **Step 1: Write the failing tests**

```swift
struct RemoteClientModelsTests {
  @Test func theKeyFileSplitsAtTheLastSlash() {
    #expect(RemoteClientKey.parse("relay.example.com/abcde-fghij\n")
      == RemoteClientKey(relayHost: "relay.example.com", key: "abcde-fghij"))
    #expect(RemoteClientKey.parse("http://10.0.2.2:8787/test-key")
      == RemoteClientKey(relayHost: "http://10.0.2.2:8787", key: "test-key"))
    for bad in ["", "onlykey", "/key", "relay.example.com/", "   "] { #expect(RemoteClientKey.parse(bad) == nil) }
  }
  @Test func theClientURLCarriesTheHost() {
    let key = RemoteClientKey(relayHost: "relay.example.com", key: "k")
    #expect(key.clientURL(hostID: "3f9a0c1d2e4b5a69")?.absoluteString == "wss://relay.example.com/client?host=3f9a0c1d2e4b5a69")
    #expect(key.clientURL(hostID: nil)?.absoluteString == "wss://relay.example.com/client")
    #expect(RemoteClientKey(relayHost: "http://10.0.2.2:8787", key: "k").clientURL(hostID: nil)?.absoluteString
      == "ws://10.0.2.2:8787/client")
  }
  @Test func theProtocolDocsListExampleDecodes() throws {
    // The `list` JSON from docs/remote-access-protocol.md, with `sections` and a `layout`.
    guard case .list(let list) = RemoteClientFrame.decode(Self.listExample) else { Issue.record("not a list"); return }
    #expect(list.repos.first?.worktrees.first?.tabs.first?.agents.first?.activity == "busy")
    #expect(list.repos.first?.worktrees.first?.layout?.groups.first?.id == "main")
  }
  @Test func unknownStringsAndMissingFieldsStillDecode() {   // РФ2
    let text = #"{"t":"list","id":null,"repos":[{"id":"r","worktrees":[{"id":"w","status":"future","tabs":[{"id":"t","agents":[{"agent":"x","activity":"dreaming"}]}]}]}],"sections":[{"kind":"shelf"}]}"#
    guard case .list(let list) = RemoteClientFrame.decode(text) else { Issue.record("not a list"); return }
    #expect(list.repos[0].worktrees[0].status == "future")
    #expect(list.repos[0].worktrees[0].layout == nil)
    #expect(list.repos[0].worktrees[0].tabs[0].agents[0].activity == "dreaming")
    #expect(list.sections[0].kind == "shelf")
    #expect(list.canRefreshWorktrees == false)
  }
  @Test func theLayoutNodeDecodesBothShapes() throws { /* {"pane":"A"} and {"split":{…}} */ }
  @Test func relayWithoutHostsIsAnOldRelay() {
    guard case .relay(let status) = RemoteClientFrame.decode(#"{"t":"relay","hostOnline":true}"#) else { return }
    #expect(status.hosts == nil)
  }
  @Test func outDecodesItsBytes() {
    #expect(RemoteClientFrame.decode(#"{"t":"out","contentId":"C","b64":"DQ=="}"#) == .out(contentId: "C", bytes: [0x0D]))
  }
  @Test func anErrorKeepsItsCode() {
    #expect(RemoteClientFrame.decode(#"{"t":"error","id":8,"message":"m","code":"worktree_dirty"}"#)
      == .error(id: 8, message: "m", code: "worktree_dirty", contentId: nil))
  }
  @Test func anotherReplyKeepsItsStringFields() {
    #expect(RemoteClientFrame.decode(#"{"t":"pane.split","id":7,"worktreeId":"/w","paneId":"P","tabId":"T","contentId":"T"}"#)
      == .reply(t: "pane.split", id: 7, fields: ["worktreeId": "/w", "paneId": "P", "tabId": "T", "contentId": "T"]))
  }
  @Test func pongAndGarbageAreNoFrame() {
    #expect(RemoteClientFrame.decode("pong") == nil)
    #expect(RemoteClientFrame.decode("{}") == nil)
  }
}
```

- [ ] **Step 2: Run `supacodeTests/RemoteClientModelsTests`; expect compile failure.**
- [ ] **Step 3: Implement the two files.**
- [ ] **Step 4: Run the suite; expect PASS.**
- [ ] **Step 5: Commit** (`feat(remote-client): the key file and tolerant protocol models`).

### Task 2: The query filter (ТР4)

**Files:**
- Create: `supacode/Features/RemoteClient/RemoteQueryFilter.swift`
- Test: `supacodeTests/RemoteClientQueryFilterTests.swift`

**Interfaces:**
- Produces:

```swift
/// Drops terminal queries (and Supacode's OSC 3008) from a remote terminal's output.
nonisolated struct RemoteQueryFilter: Sendable {
  static let maxPending = 4096
  /// The bytes for the local terminal; an unfinished sequence waits for the next call.
  mutating func push(_ bytes: [UInt8]) -> [UInt8]
}
```

This is a port of `supacode-remote/web/src/query-filter.mjs`, state for state (`ground`, `esc`,
`csi`, `osc`, `dcs`, `osc-esc`, `dcs-esc`), with one addition: an OSC whose number is `3008` is
dropped, whether it ends in BEL or `ESC \`. Dropped: CSI finals `c` (prefix none, `>`, `=`), `n`
(none, `?`), `p` with a `$` intermediate, `q` with `>`, every `t`, `u` with `?`; OSC `4`, `10`,
`11`, `12` whose body has a `?` after the first `;`; DCS starting with `$q` or `+q`. CAN or SUB
ends a sequence and lets it through. An ESC inside a CSI lets the pending bytes through, emits
CAN, and starts a new sequence. More than 4096 pending bytes are let through.

- [ ] **Step 1: Write the failing tests.** Port every case of
  `supacode-remote/web/test/query-filter.test.mjs` to Swift Testing with the same inputs and
  expected bytes, and add:

```swift
@Test func supacodesPresenceSignalIsDroppedInBothEndings() {
  var filter = RemoteQueryFilter()
  #expect(filter.push(Array("a\u{1b}]3008;x=1\u{07}b".utf8)) == Array("ab".utf8))
  #expect(filter.push(Array("\u{1b}]3008;y\u{1b}\\c".utf8)) == Array("c".utf8))
}
@Test func aQuerySplitAcrossTwoPushesIsDroppedWhole() {   // РФ1
  var filter = RemoteQueryFilter()
  #expect(filter.push([0x1b, 0x5b]).isEmpty)
  #expect(filter.push(Array("c!".utf8)) == Array("!".utf8))
}
@Test func aBrokenSequenceIsLetThroughAfterTheCap() {      // РФ1
  var filter = RemoteQueryFilter()
  let broken = [0x1b, 0x5d] + [UInt8](repeating: 0x41, count: RemoteQueryFilter.maxPending)
  #expect(filter.push(broken) == broken)
}
@Test func aTitleAndAColourSetPass() {
  var filter = RemoteQueryFilter()
  let text = Array("\u{1b}]2;title\u{07}\u{1b}]10;#ffffff\u{07}\u{1b}[31m".utf8)
  #expect(filter.push(text) == text)
}
```

- [ ] **Step 2: Run `supacodeTests/RemoteClientQueryFilterTests`; expect compile failure.**
- [ ] **Step 3: Implement `RemoteQueryFilter`.**
- [ ] **Step 4: Run the suite; expect PASS.**
- [ ] **Step 5: Commit** (`feat(remote-client): query filter for a remote terminal's output`).

### Task 3: LAN trust and the stream gate (КЛ3, КЛ4)

**Files:**
- Create: `supacode/Features/RemoteClient/RemoteLANTrust.swift`
- Create: `supacode/Features/RemoteClient/RemoteStreamGate.swift`
- Test: `supacodeTests/RemoteClientGateTests.swift`

**Interfaces:**
- Consumes: `RemoteLANIdentity.fingerprint(der:)`, `RemoteLANIdentity.fingerprintMAC(fingerprint:clientKey:)`.
- Produces:

```swift
nonisolated enum RemoteLANTrust {
  /// `fpMac` is the HMAC the host makes; compared in constant time, hex case of `fpMac` ignored.
  static func fpMacValid(clientKey: String, fp: String, fpMac: String) -> Bool
  /// The leaf certificate's SHA-256 equals the pinned `fp` (constant time, case ignored).
  static func pinMatches(der: Data, fp: String) -> Bool
}

nonisolated enum RemoteClientPath: Hashable, Sendable { case relay, lan }

/// Which path carries ONE terminal's stream. One gate per attached content.
nonisolated struct RemoteStreamGate: Sendable {
  enum Kind: Sendable { case attached(id: Int?), out, size, detached }
  struct Verdict: Equatable, Sendable { var deliver: Bool; var detach: [RemoteClientPath] }
  private(set) var current: RemoteClientPath?
  /// An `attach` with this request id left on `path`. Call before its reply can arrive.
  mutating func attachSent(on path: RemoteClientPath, id: Int)
  /// A `detach` left on `path`; returns the other paths that still hold an attach.
  mutating func detachSent(on path: RemoteClientPath) -> [RemoteClientPath]
  /// The path's socket closed: the host forgot the attach there.
  mutating func closed(_ path: RemoteClientPath)
  /// Whether the frame reaches the terminal, and on which paths a `detach` must go out now.
  mutating func accept(from path: RemoteClientPath, _ kind: Kind) -> Verdict
}
```

Rules (from `web/src/stream-gate.mjs`, for one content): an `attached` that answers the pending
attach (same path; same id, or no id) makes that path current and returns the other attached
paths in `detach`; a frame from a path that is not current is not delivered; `closed` of the
current path clears it; `detachSent` on any path clears the pending attach and the current path.

- [ ] **Step 1: Write the failing tests**

```swift
struct RemoteClientGateTests {
  static let key = "abcde-fghij-klmno-pqrst-uvwxy-z2345"
  static let fp = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
  static let fpMac = "e1bef7bccaed983a401062bd7faa05f9fa1a1ca2315570c82009429bdde65a77"

  @Test func theSharedVectorIsValid() {
    #expect(RemoteLANTrust.fpMacValid(clientKey: Self.key, fp: Self.fp, fpMac: Self.fpMac))
    #expect(RemoteLANTrust.fpMacValid(clientKey: Self.key, fp: Self.fp, fpMac: Self.fpMac.uppercased()))
  }
  @Test func anyDifferenceIsInvalid() {
    #expect(!RemoteLANTrust.fpMacValid(clientKey: Self.key + "-x", fp: Self.fp, fpMac: Self.fpMac))
    #expect(!RemoteLANTrust.fpMacValid(clientKey: Self.key, fp: Self.fp.uppercased(), fpMac: Self.fpMac))
    #expect(!RemoteLANTrust.fpMacValid(clientKey: Self.key, fp: Self.fp, fpMac: String(Self.fpMac.dropLast(2))))
    #expect(!RemoteLANTrust.fpMacValid(clientKey: Self.key, fp: Self.fp, fpMac: "zz" + Self.fpMac.dropFirst(2)))
    #expect(!RemoteLANTrust.fpMacValid(clientKey: Self.key, fp: "", fpMac: Self.fpMac))
  }
  @Test func thePinComparesTheDERFingerprint() {
    let der = Data("certificate".utf8)
    #expect(RemoteLANTrust.pinMatches(der: der, fp: RemoteLANIdentity.fingerprint(der: der).uppercased()))
    #expect(!RemoteLANTrust.pinMatches(der: der, fp: Self.fp))
  }

  @Test func theFirstAttachedMakesItsPathCurrent() {
    var gate = RemoteStreamGate()
    gate.attachSent(on: .relay, id: 2)
    #expect(gate.accept(from: .relay, .out) == .init(deliver: false, detach: []))
    #expect(gate.accept(from: .relay, .attached(id: 2)) == .init(deliver: true, detach: []))
    #expect(gate.accept(from: .relay, .out) == .init(deliver: true, detach: []))
  }
  @Test func aNewPathTakesOverOnlyAtItsAttached() {            // РФ4
    var gate = RemoteStreamGate()
    gate.attachSent(on: .relay, id: 2); _ = gate.accept(from: .relay, .attached(id: 2))
    gate.attachSent(on: .lan, id: 3)
    #expect(gate.accept(from: .relay, .out).deliver)            // the old stream still runs
    #expect(gate.accept(from: .lan, .out).deliver == false)
    #expect(gate.accept(from: .lan, .attached(id: 3)) == .init(deliver: true, detach: [.relay]))
    #expect(gate.accept(from: .relay, .out).deliver == false)   // late frames of the old path
  }
  @Test func anAttachedWithAnotherIdDoesNotSwitch() {
    var gate = RemoteStreamGate()
    gate.attachSent(on: .lan, id: 3)
    #expect(gate.accept(from: .lan, .attached(id: 9)).deliver == false)
  }
  @Test func aClosedCurrentPathStopsItsFrames() {
    var gate = RemoteStreamGate()
    gate.attachSent(on: .lan, id: 3); _ = gate.accept(from: .lan, .attached(id: 3))
    gate.closed(.lan)
    #expect(gate.current == nil)
    #expect(gate.accept(from: .lan, .out).deliver == false)
  }
  @Test func detachNamesTheOtherAttachedPaths() {
    var gate = RemoteStreamGate()
    gate.attachSent(on: .relay, id: 2); _ = gate.accept(from: .relay, .attached(id: 2))
    gate.attachSent(on: .lan, id: 3)
    #expect(gate.detachSent(on: .relay) == [.lan])
    #expect(gate.current == nil)
  }
}
```

- [ ] **Step 2: Run `supacodeTests/RemoteClientGateTests`; expect compile failure.**
- [ ] **Step 3: Implement both types.**
- [ ] **Step 4: Run the suite; expect PASS.**
- [ ] **Step 5: Commit** (`feat(remote-client): LAN trust check and a per-terminal stream gate`).

### Task 4: Host choice and the awaiting tracker (МХ1, МХ2, ИВ1)

**Files:**
- Create: `supacode/Features/RemoteClient/RemoteHostChoice.swift`
- Create: `supacode/Features/RemoteClient/RemoteAwaitingTracker.swift`
- Test: `supacodeTests/RemoteClientChoiceTests.swift`

**Interfaces:**
- Produces:

```swift
nonisolated enum RemoteHostChoice {
  enum Decision: Equatable { case none, select(String), askUser }
  /// `hosts` nil: an old relay (single host) → .none. This Mac (`ownHostID`) never counts.
  static func decide(saved: String?, hosts: [RemoteClientHostInfo]?, ownHostID: String?) -> Decision
  /// The picker's rows: every host except this Mac.
  static func pickable(_ hosts: [RemoteClientHostInfo], ownHostID: String?) -> [RemoteClientHostInfo]
}

nonisolated struct RemoteAwaitingTab: Equatable, Sendable {
  let contentId: String; let repositoryId: String; let worktreeId: String
  let worktreeName: String; let tabTitle: String; let agent: String
}
nonisolated struct RemoteAwaitingTracker: Sendable {
  struct Changes: Equatable { var started: [RemoteAwaitingTab]; var ended: [String] }
  /// The first snapshot after init or reset only records who waits; it starts nothing.
  mutating func update(_ repos: [RemoteClientRepository]) -> Changes
  /// Switching the Mac or closing the window: the content ids whose notifications go.
  mutating func reset() -> [String]
}
```

A tab waits when one of its agents has the activity `awaitingInput`. `worktreeName` is the
worktree's `title` when it is set and not blank, else its `name`; a blank tab title is `Tab`.

- [ ] **Step 1: Write the failing tests**

```swift
struct RemoteClientChoiceTests {
  static func host(_ id: String, online: Bool) -> RemoteClientHostInfo { .init(id: id, name: id, online: online) }

  @Test func anOldRelayNeedsNoChoice() { #expect(RemoteHostChoice.decide(saved: nil, hosts: nil, ownHostID: "me") == .none) }
  @Test func aSavedHostInTheListStays() {
    #expect(RemoteHostChoice.decide(saved: "a", hosts: [Self.host("a", online: false)], ownHostID: "me") == .none)
  }
  @Test func aSavedHostMissingFromTheListAsks() {
    #expect(RemoteHostChoice.decide(saved: "gone", hosts: [Self.host("a", online: true)], ownHostID: "me") == .askUser)
  }
  @Test func exactlyOneOtherOnlineHostIsSelected() {
    let hosts = [Self.host("me", online: true), Self.host("a", online: true), Self.host("b", online: false)]
    #expect(RemoteHostChoice.decide(saved: nil, hosts: hosts, ownHostID: "me") == .select("a"))
  }
  @Test func noneOrSeveralOnlineAsks() {
    #expect(RemoteHostChoice.decide(saved: nil, hosts: [Self.host("me", online: true)], ownHostID: "me") == .askUser)
    let two = [Self.host("a", online: true), Self.host("b", online: true)]
    #expect(RemoteHostChoice.decide(saved: nil, hosts: two, ownHostID: "me") == .askUser)
  }
  @Test func thePickerLeavesThisMacOut() {
    #expect(RemoteHostChoice.pickable([Self.host("me", online: true), Self.host("a", online: true)], ownHostID: "me").map(\.id) == ["a"])
  }

  // `repos(awaiting:)` builds one repo, one worktree and one tab per content id; the listed ones wait.
  @Test func theFirstSnapshotStartsNothing() {
    var tracker = RemoteAwaitingTracker()
    #expect(tracker.update(Self.repos(all: ["t1"], awaiting: ["t1"])) == .init(started: [], ended: []))
  }
  @Test func aTabThatStartsToWaitIsReportedOnce() {
    var tracker = RemoteAwaitingTracker()
    _ = tracker.update(Self.repos(all: ["t1"], awaiting: []))
    #expect(tracker.update(Self.repos(all: ["t1"], awaiting: ["t1"])).started.map(\.contentId) == ["t1"])
    #expect(tracker.update(Self.repos(all: ["t1"], awaiting: ["t1"])).started.isEmpty)
  }
  @Test func aTabThatStopsOrVanishesEnds() {
    var tracker = RemoteAwaitingTracker()
    _ = tracker.update(Self.repos(all: ["t1", "t2"], awaiting: []))
    _ = tracker.update(Self.repos(all: ["t1", "t2"], awaiting: ["t1", "t2"]))
    #expect(Set(tracker.update(Self.repos(all: ["t1"], awaiting: [])).ended) == ["t1", "t2"])
  }
  @Test func resetForgetsAndTheNextSnapshotStartsNothing() {
    var tracker = RemoteAwaitingTracker()
    _ = tracker.update(Self.repos(all: ["t1"], awaiting: []))
    _ = tracker.update(Self.repos(all: ["t1"], awaiting: ["t1"]))
    #expect(tracker.reset() == ["t1"])
    #expect(tracker.update(Self.repos(all: ["t1"], awaiting: ["t1"])).started.isEmpty)
  }
}
```

- [ ] **Step 2: Run `supacodeTests/RemoteClientChoiceTests`; expect compile failure.**
- [ ] **Step 3: Implement both types.**
- [ ] **Step 4: Run the suite; expect PASS.**
- [ ] **Step 5: Commit** (`feat(remote-client): host choice and the awaiting tracker`).

### Task 5: The sockets — relay and pinned LAN (КЛ2, КЛ3)

**Files:**
- Create: `supacode/Features/RemoteClient/RemoteClientSocket.swift`
- Test: `supacodeTests/RemoteClientSocketTests.swift`

**Interfaces:**
- Consumes: `RemoteLANTrust.pinMatches`; `RemoteLANServer` (the host's listener, for the test).
- Produces:

```swift
nonisolated enum RemoteClientSocketEvent: Equatable, Sendable {
  case opened
  case text(String)
  case closed(reason: String)
}
/// One WebSocket. `events` ends after `.closed`.
protocol RemoteClientSocket: AnyObject, Sendable {
  var events: AsyncStream<RemoteClientSocketEvent> { get }
  func send(_ text: String)
  func close()
}
nonisolated struct RemoteClientSocketFactory: Sendable {
  /// wss (or ws) to the relay with `Authorization: Bearer <key>`.
  var relay: @Sendable (_ url: URL, _ key: String) -> any RemoteClientSocket
  /// wss://<addr>:<port>/lan, TLS 1.3 only, the leaf certificate pinned to `fp`, the key in `Authorization`.
  var lan: @Sendable (_ addr: String, _ port: Int, _ fp: String, _ key: String) -> any RemoteClientSocket
  static let live: RemoteClientSocketFactory
}
```

This task starts with a spike, because the spec lists the mechanism as not confirmed.

- [ ] **Step 1: Spike — one throwaway test, not committed.** With `NWConnection` and
  `NWProtocolWebSocket.Options` (`setAdditionalHeaders` for `Authorization`),
  `NWProtocolTLS.Options` with the minimum version TLS 1.3 and a
  `sec_protocol_options_set_verify_block` that takes the leaf certificate's DER
  (`sec_trust_copy_ref` → `SecTrustCopyCertificateChain`) and calls `RemoteLANTrust.pinMatches`,
  connect to a `RemoteLANServer` started in the test (as `RemoteAccessLANServerTests` starts one).
  **Pass:** the right `fp` and key reach `.ready` with the response header `X-Supacode-LAN: 1` and a
  `ping` gets `pong`; a wrong `fp` fails the handshake and the server sees no upgrade request; a
  wrong key never yields `.opened`. **Fallback when it does not pass:** `URLSessionWebSocketTask`
  with a `URLSessionDelegate` whose `urlSession(_:didReceive:completionHandler:)` pins the server
  trust the same way and `tlsMinimumSupportedProtocolVersion = .TLSv13`; the interfaces above do
  not change. Record which one passed in the file's header comment.

- [ ] **Step 2: Write the failing tests** (the three spike cases become the suite, plus the relay
  socket against a local plain `NWListener` WebSocket echo that checks the `Authorization` header).
  A refused connection is asserted through `.closed` with a bounded wait on the stream, never
  through send or receive (`.agent-memory/nwwebsocket-reject-stays-ready.md`): `.opened` is emitted
  for the LAN only after the accepted-upgrade marker header was seen.

```swift
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteClientSocketTests {
  @Test func theLANSocketOpensWithTheRightPinAndKey() async throws { /* events: .opened; send "ping" → .text("pong") */ }
  @Test func aWrongPinNeverOpens() async throws { /* first event is .closed; the server accepted no peer */ }
  @Test func aWrongKeyNeverOpens() async throws { /* first event is .closed */ }
  @Test func theRelaySocketSendsTheBearerKey() async throws { /* the listener saw "Bearer k"; echo arrives as .text */ }
  @Test func closeEndsTheStream() async throws { /* after close(): .closed, then the stream finishes */ }
}
```

- [ ] **Step 3: Implement** the two socket classes and `RemoteClientSocketFactory.live` with the
  mechanism that passed.
- [ ] **Step 4: Run `supacodeTests/RemoteClientSocketTests`; expect PASS.**
- [ ] **Step 5: Commit** (`feat(remote-client): relay and pinned LAN WebSocket clients`).

### Task 6: The connection (КЛ2–КЛ7, МХ3, МХ4, ТР8в)

**Files:**
- Create: `supacode/Features/RemoteClient/RemoteClientConnection.swift`
- Test: `supacodeTests/RemoteClientConnectionTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 3, 5.
- Produces:

```swift
nonisolated enum RemoteClientStatus: Equatable, Sendable {
  case idle
  case connecting                 // no relay socket yet, or waiting to retry
  case choosingHost               // connected unbound; the picker decides
  case hostOffline
  case online(RemoteClientPath)
  case unsupportedHost            // hello without every capability the client needs
  case failed(String)             // 401, 403, a bad key file: no retry
}
nonisolated enum RemoteTerminalEvent: Equatable, Sendable {
  case attached(cols: Int, rows: Int)
  case out([UInt8])
  case size(cols: Int, rows: Int)
  case detached(reason: String)
}
nonisolated struct RemoteClientRequestError: Error, Equatable {
  enum Kind: Equatable { case host, timeout, connectionLost, notConnected }
  let kind: Kind; let message: String; let code: String?
}

@MainActor @Observable
final class RemoteClientConnection {
  static let requiredCaps: Set<String> = ["attach.keep", "watch", "layout", "tab.close", "pane.split", "pane.close", "resize.hold"]
  static let retryDelays: [Duration] = [.seconds(3), .seconds(6), .seconds(12), .seconds(30)]   // the last repeats
  static let lanConnectTimeout: Duration = .milliseconds(2500)
  static let pingInterval: Duration = .seconds(30)

  init(key: RemoteClientKey, ownHostID: String?, sockets: RemoteClientSocketFactory, clock: any Clock<Duration>)

  private(set) var status: RemoteClientStatus
  private(set) var hosts: [RemoteClientHostInfo]?
  private(set) var hostName: String?
  private(set) var list: RemoteClientList?
  /// Grows with every `list` frame, so observers react to a list that arrived.
  private(set) var listRevision: Int

  /// Connects bound to `hostID`, or unbound (nil) to read the host list. Closes any open sockets first.
  func start(hostID: String?)
  func stop()

  /// A request with an `id`; resolves with the reply's string fields, or throws the host's error,
  /// a timeout, or `connectionLost` when the path that carried it closes (the wait is not retried).
  func request(_ t: String, _ fields: [String: String], ints: [String: Int] = [:], timeout: Duration) async throws -> [String: String]

  /// Attaches with `keep:true` and yields that terminal's frames, already gated to one path.
  /// The stream ends when `detach(contentID:)` is called or the connection stops.
  func attach(contentID: String, scrollback: Int) -> AsyncStream<RemoteTerminalEvent>
  func detach(contentID: String)
  /// Dropped (returns false) unless the status is `.online`.
  @discardableResult func sendInput(contentID: String, bytes: [UInt8]) -> Bool
  /// The wanted grid of one attached terminal; sent as `resize` with `hold:true` now, and again
  /// after every later `attached` of that terminal, before the old path's `detach`.
  func setWantedGrid(contentID: String, columns: Int, rows: Int)
}
```

Behaviour, in order of a frame's life:
- Relay: connect to `key.clientURL(hostID:)`; a text `ping` every `pingInterval`. `relay` frames
  update `hosts` and `status`; only a `hostOnline` false → true edge sends `hello`.
- `hello` reply: `hostName`; missing any of `requiredCaps` → `.unsupportedHost`, nothing more is
  sent. Otherwise send `list`, `watch` (`on:true`), and re-attach every open terminal (`keep:true`).
  When the reply has `lan`, its `hostId` is absent or equals the bound host, and
  `RemoteLANTrust.fpMacValid` holds: try each address with `lanConnectTimeout`; the first that
  opens becomes the LAN path: `hello`, `list`, `watch` and the attaches go out on it, the relay
  socket stays open with ping only.
- Every terminal frame passes its content's `RemoteStreamGate`; delivered ones are yielded. When
  the gate's verdict names paths to detach, the client first sends that terminal's wanted
  `resize` with `hold:true` on the new path, then `detach` on the named paths (ТР8в).
- The LAN socket closing returns to the relay path and re-attaches there. The relay socket
  closing ends every wait that travelled on it and retries after `retryDelays`; a close with an
  HTTP 401 or 403 sets `.failed` and does not retry.
- `list` frames (replies and pushed ones) replace `list` and bump `listRevision`.

- [ ] **Step 1: Write the failing tests.** A `FakeSocket` (test-only, `nonisolated deinit {}` when
  it is a main-actor class) records sent texts and lets the test emit events; a factory hands out
  fakes and records the URLs and LAN arguments. All time is a `TestClock`.

```swift
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteClientConnectionTests {
  @Test func nothingIsSentBeforeTheHostIsOnline() async { /* opened + relay hostOnline:false → sent == [] ; status .hostOffline */ }
  @Test func theOnlineEdgeSendsHelloOnce() async {             // РФ3
    // relay false → true → sent t's == ["hello"]; a second relay hostOnline:true → still one hello
  }
  @Test func helloWithEveryCapAsksForListAndWatch() async { /* after hello reply: "list", then "watch" with on:true; status .online(.relay) */ }
  @Test func aHostWithoutACapIsUnsupported() async { /* caps missing "resize.hold" → .unsupportedHost; nothing sent after hello */ }
  @Test func anUnboundStartOnlyReadsTheHostList() async { /* start(hostID: nil): URL has no host=; hosts set; status .choosingHost; nothing sent */ }
  @Test func aRequestResolvesWithItsReply() async throws { /* request("tab.new", …) → reply id matches → fields */ }
  @Test func aHostErrorThrowsWithItsCode() async { /* error id matches → .host, code "worktree_dirty", the host's message */ }
  @Test func aRequestTimesOut() async { /* advance past timeout → .timeout */ }
  @Test func aLostConnectionEndsTheWait() async { /* socket closed → .connectionLost; no retry is sent after reconnect */ }
  @Test func attachSendsKeepAndYieldsGatedFrames() async { /* "attach" has keep:true; attached, out → events in order */ }
  @Test func inputIsDroppedWhileOffline() async { /* sendInput returns false and sends nothing when status != .online */ }
  @Test func aValidLanOfferOpensTheLanPath() async { /* hello with lan + valid fpMac → factory.lan called; after its opened: hello/list/watch/attach on LAN; status .online(.lan) */ }
  @Test func aBadFpMacMakesNoLanAttempt() async { /* factory.lan never called */ }
  @Test func aHelloFromAnotherHostMakesNoLanAttempt() async { /* hostId differs from the bound host */ }
  @Test func aPathSwitchResizesBeforeItDetaches() async {      // РФ4
    // two terminals attached on relay with wanted grids; LAN opens; for each: on LAN "attach" keep:true,
    // then after LAN `attached`: LAN "resize" hold:true BEFORE relay "detach"; a late relay `out` is not yielded
  }
  @Test func theLanClosingFallsBackToTheRelayAndReattaches() async { /* status .online(.relay); "attach" keep:true on relay */ }
  @Test func reconnectsWaitThreeSecondsAndMore() async { /* closed → no new socket before 3 s; then 6, 12, 30, 30 */ }
  @Test func aRefusedKeyDoesNotRetry() async { /* closed(reason: "401") → .failed; advance 60 s → no new socket */ }
  @Test func stopClosesBothSocketsAndEndsTheStreams() async { }
}
```

- [ ] **Step 2: Run `supacodeTests/RemoteClientConnectionTests`; expect compile failure.**
- [ ] **Step 3: Implement `RemoteClientConnection`.** Request ids are a counter per connection
  object; the JSON is built with `JSONSerialization` from the fields. Sockets' `closed(reason:)`
  carries the HTTP status as text when the upgrade was refused (the socket classes of Task 5 put it
  there).
- [ ] **Step 4: Run the suite; expect PASS.**
- [ ] **Step 5: Commit** (`feat(remote-client): the connection — relay, LAN path, requests, attaches`).

---

## Stage ЕТ3 — one remote tab in the new window

### Task 7: The pipe — app side and the CLI command (ТР2, ТР3)

**Files:**
- Create: `supacode/Features/RemoteClient/RemotePipeServer.swift`
- Create: `supacode-cli/Commands/RemotePipeCommand.swift`
- Modify: `supacode-cli/SupacodeCLI.swift` (add `RemotePipeCommand.self` to `subcommands`)
- Test: `supacodeTests/RemoteClientPipeTests.swift`

**Interfaces:**
- Produces:

```swift
nonisolated enum RemotePipeProtocol {
  static let socketVariable = "SUPACODE_REMOTE_PIPE_SOCKET"
  static let tokenVariable = "SUPACODE_REMOTE_PIPE_TOKEN"
  /// "SUPACODE-PIPE 1 <token> <contentId>\n"
  static func header(token: String, contentID: String) -> [UInt8]
  /// nil unless the line is exactly a version-1 header.
  static func parseHeader(_ line: String) -> (token: String, contentID: String)?
}

@MainActor
final class RemotePipeServer {
  /// A unix socket `remote-pipe-<pid>.sock`, mode 0600, in `directory` (the CLI socket's directory:
  /// its path is short enough for `sun_path`).
  init(directory: URL)
  var socketPath: String { get }
  func start() throws
  func stop()
  /// A one-time token for the pipe of this content; the surface gets it in its environment.
  func expect(contentID: String) -> String
  func forget(contentID: String)
  /// Bytes for the local terminal. Dropped while that content has no open pipe.
  func write(contentID: String, _ bytes: [UInt8])
  var onOpened: (@MainActor (_ contentID: String) -> Void)?
  var onInput: (@MainActor (_ contentID: String, _ bytes: [UInt8]) -> Void)?
  var onClosed: (@MainActor (_ contentID: String) -> Void)?
}
```

CLI: `supacode remote-pipe <contentId>` with `shouldDisplay: false`. It reads the two environment
variables (missing: a message on stderr and exit 1), sets stdin to raw mode (`cfmakeraw`), ignores
`SIGWINCH`, connects, writes the header, then copies stdin → socket and socket → stdout until either
side reaches EOF; it restores the terminal attributes on every exit path and exits 0.

A connection with a bad header, an unknown token or a content that already has a pipe is closed at
once. A token works once.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteClientPipeTests {
  @Test func theHeaderRoundTrips() {
    let line = String(decoding: RemotePipeProtocol.header(token: "tok", contentID: "C1"), as: UTF8.self)
    #expect(line == "SUPACODE-PIPE 1 tok C1\n")
    #expect(RemotePipeProtocol.parseHeader("SUPACODE-PIPE 1 tok C1")?.contentID == "C1")
    for bad in ["", "SUPACODE-PIPE 2 tok C1", "PIPE 1 tok C1", "SUPACODE-PIPE 1 tok", "SUPACODE-PIPE 1 tok C1 extra"] {
      #expect(RemotePipeProtocol.parseHeader(bad) == nil)
    }
  }
  // The next tests open a plain unix socket client to `server.socketPath` from the test.
  @Test func aPipeWithTheRightTokenCarriesBytesBothWays() async throws {
    // expect("C1") → token; client sends header + "ls\r" → onOpened("C1"), onInput("C1", "ls\r");
    // server.write("C1", "out") → the client reads "out"; client closes → onClosed("C1")
  }
  @Test func aWrongTokenIsClosedAndReportsNothing() async throws { /* the client reads EOF; no onOpened */ }
  @Test func aTokenWorksOnce() async throws { /* a second connection with the same token is closed */ }
  @Test func theSocketFileIsPrivate() throws { /* POSIX permissions of socketPath == 0o600 */ }
  @Test func writesBeforeThePipeOpensAreDropped() async throws { /* write, then connect: nothing is read before the next write */ }
}
```

- [ ] **Step 2: Run `supacodeTests/RemoteClientPipeTests`; expect compile failure.**
- [ ] **Step 3: Implement `RemotePipeProtocol` and `RemotePipeServer`** (a `DispatchSource` or
  `NWListener` on the unix socket; reads never block the main actor), then `RemotePipeCommand`.
  The header is shared text, so the CLI target gets its own copy of the two constants and the header
  format; the test above pins the format.
- [ ] **Step 4: Run the suite; expect PASS.**
- [ ] **Step 5: Try the command by hand.** In a terminal:
  `SUPACODE_REMOTE_PIPE_SOCKET=/nonexistent SUPACODE_REMOTE_PIPE_TOKEN=x supacode remote-pipe C1`
  prints one error line, exits 1 and leaves the terminal usable (echo works); `supacode --help` does
  not list `remote-pipe`.
- [ ] **Step 6: Commit** (`feat(remote-client): byte pipe between a surface and the app`).

### Task 8: The remote terminal content (ТР1, ТР4–ТР9)

**Files:**
- Create: `supacode/Features/RemoteClient/RemoteTerminalContent.swift`
- Create: `supacode/Features/RemoteClient/RemoteAutoResize.swift`
- Test: `supacodeTests/RemoteClientTerminalTests.swift`

**Interfaces:**
- Consumes: `RemoteClientConnection` (Task 6), `RemotePipeServer` (Task 7), `RemoteQueryFilter`
  (Task 2), `GhosttySurfaceView.pinGrid(columns:rows:)` / `unpinGrid()` (host plan, Task 8).
- Produces:

```swift
/// When the client asks the host for a new size (ТР8).
nonisolated struct RemoteAutoResize: Sendable {
  static let settle: Duration = .milliseconds(200)
  struct Grid: Equatable, Sendable { let columns: Int; let rows: Int }
  enum Step: Equatable { case nothing, schedule, send(Grid) }
  /// The pane's fitting grid was measured (a layout pass). `.schedule`: start or restart the 200 ms timer.
  mutating func paneMeasured(_ grid: Grid) -> Step
  /// The 200 ms passed with no newer measurement.
  mutating func settled() -> Step
  /// An `attached` arrived with the remote grid.
  mutating func attached(remote: Grid) -> Step
  /// A `size` arrived. Never a reason to send.
  mutating func sizeReceived(_ remote: Grid)
}

/// The bytes the client writes to the local terminal around the stream.
nonisolated enum RemoteTerminalBytes {
  /// CSI 3 J, CSI 2 J, CSI H — before the redraw of a new `attached` (ТР6).
  static let clearForRedraw: [UInt8]
}

@MainActor @Observable
final class RemoteTerminalContent: TabContent {
  enum Phase: Equatable { case starting, live, ended(reason: String) }
  init(remoteContentID: String, title: String, connection: RemoteClientConnection, pipes: RemotePipeServer,
       runtime: GhosttyRuntime, clock: any Clock<Duration>)
  let remoteContentID: String
  private(set) var phase: Phase
  private(set) var remoteGrid: RemoteAutoResize.Grid?
  /// TabContent: `kind` is `.terminal`; `snapshot()` is a plain terminal snapshot that is never persisted;
  /// `isHibernatable` is false; `renderer` is the surface view.
}
```

Rules of `RemoteAutoResize`: `paneMeasured` with a grid equal to the last measured one is
`.nothing`, otherwise `.schedule`; `settled` is `.send(measured)` when the measured grid differs
from the remote grid and there is an `attached` terminal, else `.nothing`; `attached(remote:)` is
`.send(measured)` when a pane grid is known and differs from `remote`, else `.nothing`;
`sizeReceived` only records the remote grid.

The content: on `startSession` it makes the surface with `command` =
`"<Bundle.main.resourceURL>/bin/supacode remote-pipe <id>"` (the CLI path the app already puts on
`PATH` in `TerminalSurfaceRecipe.environment`), `disableShellIntegration: true`, no command
wrapper, and the two pipe environment variables. When the pipe opens it calls
`connection.attach(contentID:scrollback: 2000)`. For each event: `.attached` → write
`clearForRedraw`, `pinGrid`, feed `RemoteAutoResize.attached`; `.out` → `RemoteQueryFilter.push` →
`pipes.write`; `.size` → `pinGrid`, `sizeReceived`; `.detached` → `phase = .ended(reason:)`. Pipe
input → `connection.sendInput`. A `.send(grid)` step calls `connection.setWantedGrid`. `tearDown`
detaches, forgets the pipe token and closes the surface.

- [ ] **Step 1: Write the failing tests**

```swift
struct RemoteClientTerminalTests {
  typealias Grid = RemoteAutoResize.Grid

  @Test func aMeasurementSchedulesAndTheSameOneDoesNot() {
    var auto = RemoteAutoResize()
    let first = auto.paneMeasured(Grid(columns: 120, rows: 40))
    let again = auto.paneMeasured(Grid(columns: 120, rows: 40))
    #expect(first == .schedule)
    #expect(again == .nothing)
  }
  @Test func settlingSendsOnlyWhenAttachedAndDifferent() {
    var auto = RemoteAutoResize()
    _ = auto.paneMeasured(Grid(columns: 120, rows: 40))
    let beforeAttach = auto.settled()
    #expect(beforeAttach == .nothing)
    let onAttach = auto.attached(remote: Grid(columns: 180, rows: 50))
    #expect(onAttach == .send(Grid(columns: 120, rows: 40)))
    auto.sizeReceived(Grid(columns: 120, rows: 40))
    _ = auto.paneMeasured(Grid(columns: 100, rows: 30))
    let afterResize = auto.settled()
    #expect(afterResize == .send(Grid(columns: 100, rows: 30)))
  }
  @Test func anAttachedThatAlreadyFitsSendsNothing() {
    var auto = RemoteAutoResize()
    _ = auto.paneMeasured(Grid(columns: 120, rows: 40))
    let step = auto.attached(remote: Grid(columns: 120, rows: 40))
    #expect(step == .nothing)
  }
  @Test func aForeignSizeIsNeverAnswered() {
    var auto = RemoteAutoResize()
    _ = auto.paneMeasured(Grid(columns: 120, rows: 40))
    _ = auto.attached(remote: Grid(columns: 120, rows: 40))
    auto.sizeReceived(Grid(columns: 80, rows: 24))          // another client took the size
    let step = auto.settled()                                // no new pane measurement happened
    #expect(step == .nothing)
  }
  @Test func theRedrawPreambleClearsHistoryThenScreenThenHomes() {
    #expect(RemoteTerminalBytes.clearForRedraw == Array("\u{1b}[3J\u{1b}[2J\u{1b}[H".utf8))
  }
}
```

The fourth test fixes a rule the state must hold: `settled` sends only for a measurement that was
not yet sent or attached with.

- [ ] **Step 2: Run `supacodeTests/RemoteClientTerminalTests`; expect compile failure.**
- [ ] **Step 3: Implement `RemoteAutoResize` and `RemoteTerminalBytes`.**
- [ ] **Step 4: Run the suite; expect PASS.**
- [ ] **Step 5: Implement `RemoteTerminalContent`.** The pane's fitting grid comes from the
  surface's own measurement of its bounds and cell size (the values `updateSurfaceSize` computes
  before the pin stops it); expose it from `GhosttySurfaceView` as a callback
  `onPaneGridMeasured: ((_ columns: Int, _ rows: Int) -> Void)?`, called from `updateSurfaceSize`
  whether or not a pin holds. The 200 ms timer runs on the injected clock.
- [ ] **Step 6: Commit** (`feat(remote-client): a tab whose terminal lives on another Mac`).

### Task 9: The window, with one tab (ПЗ1, ПЗ2) — and the grid spike

**Files:**
- Create: `supacode/Features/RemoteClient/RemoteClientFeature.swift` (the first slice)
- Create: `supacode/Features/RemoteClient/Views/RemoteClientWindowView.swift`
- Create: `supacode/Features/RemoteClient/RemoteClientSession.swift`
- Modify: `supacode/App/WindowID.swift` (`static let remoteClient = "remote-client"`)
- Modify: `supacode/App/supacodeApp.swift` (the `Window` scene and the menu item)
- Test: `supacodeTests/RemoteClientFeatureTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 4, 6, 7, 8.
- Produces:

```swift
/// The live objects behind the remote window: one per window, made when it opens.
@MainActor @Observable
final class RemoteClientSession {
  init(sockets: RemoteClientSocketFactory = .live, clock: any Clock<Duration> = ContinuousClock())
  let pipes: RemotePipeServer
  let runtime: ContentRuntime          // its own instance, never ContentRuntime.liveValue
  private(set) var connection: RemoteClientConnection?    // nil without a key file
  func open(hostID: String?)           // builds the connection from the key file and starts it
  func close()                         // stops the connection, tears down every content, stops the pipes
  func content(for remoteContentID: String, title: String) -> RemoteTerminalContent   // made once, cached
}

@Reducer struct RemoteClientFeature {
  @ObservableState struct State: Equatable {
    @Shared(.appStorage("remoteClientSelectedHostID")) var selectedHostID: String?
    var status: RemoteClientStatus = .idle
    var hasKeyFile = true
    var hostName: String?
    var hosts: [RemoteClientHostInfo] = []
    var isHostPickerPresented = false
    var list: RemoteClientList?
    var selectedWorktreeID: String?
  }
  enum Action {
    case windowAppeared, windowClosed
    case statusChanged(RemoteClientStatus), hostNameChanged(String?)
    case hostsChanged([RemoteClientHostInfo]?), listChanged(RemoteClientList)
    case hostPicked(String), hostPickerDismissed, titleTapped
    case worktreeSelected(String)
  }
}
```

The reducer reaches the session through one dependency, `RemoteClientSessionClient` (a struct of
closures: `open(hostID)`, `close()`, `events() -> AsyncStream<Event>` where `Event` mirrors the
four `…Changed` actions, `ownHostID() -> String?`), so `TestStore` tests need no socket. The live
value wraps a `RemoteClientSession` the window owns. `windowAppeared`: without a key file set
`hasKeyFile = false`; otherwise `open(selectedHostID)` and start the events effect.
`hostsChanged`: run `RemoteHostChoice.decide`; `.select(id)` saves it and reopens bound to it;
`.askUser` presents the picker. `hostPicked` saves, clears `list` and `selectedWorktreeID`, reopens.
`windowClosed` closes and cancels the effect.

In this task the detail area shows the selected worktree's **first tab only**, as one
`RemoteTerminalContent` hosted in the window; the sidebar is a plain list of worktree names. Tasks
10–12 replace both.

- [ ] **Step 1: Spike — how a pinned grid sits in a pane of another size (not committed).** With
  the dev build and the host of the host plan's live check, open the window on a tab and resize the
  window slowly and fast. **Pass:** the text never reflows locally, the grid stays anchored top
  left, a larger pane shows the terminal background beside and below it, a smaller pane clips, and
  200 ms after the drag ends the grid fills the pane. **Fallback when the surface's scroll wrapper
  fights the pin** (it sets the surface frame from the scroll view's bounds): give the remote
  window's host view a fixed frame equal to the pinned grid's point size and let its parent clip
  and align it top left; `GhosttySurfaceView` itself does not change. Record the outcome in
  `RemoteTerminalContent`'s header comment and in the spec's "Not confirmed" list.

- [ ] **Step 2: Write the failing reducer tests**

```swift
@MainActor struct RemoteClientFeatureTests {
  @Test func withoutAKeyFileTheWindowExplainsAndDoesNotConnect() async { /* hasKeyFile false; open never called */ }
  @Test func theSavedHostIsOpenedOnAppear() async { /* selectedHostID "a" → open("a") */ }
  @Test func nothingSavedAndOneOtherMacOnlineSelectsIt() async {
    // open(nil); hostsChanged([me online, a online]) → selectedHostID == "a"; open("a")
  }
  @Test func nothingSavedAndTwoOnlineAsks() async { /* isHostPickerPresented == true; no second open */ }
  @Test func aSavedHostMissingFromTheListAsksAndKeepsTheSelection() async { }
  @Test func pickingAHostClearsTheOldMacsState() async { /* list == nil, selectedWorktreeID == nil, open(new) */ }
  @Test func anOldRelayNeverShowsThePicker() async { /* hostsChanged(nil) → no picker */ }
  @Test func theFirstListSelectsTheWorktreeTheMacShows() async { /* the worktree with focused:true; else the first */ }
  @Test func closingTheWindowClosesTheSession() async { }
}
```

`@Shared` app storage leaks between tests: each test that sets `selectedHostID` resets it with
`defer` (`.agent-memory/test-and-lint-traps.md`).

- [ ] **Step 3: Run `supacodeTests/RemoteClientFeatureTests`; expect compile failure.**
- [ ] **Step 4: Implement** the session, the client dependency, this slice of the reducer, the
  window view (title: the Mac's name and "LAN" / "Relay" from `status`; tapping the name sends
  `titleTapped`; the picker lists `RemoteHostChoice.pickable` with an online dot; the three empty
  states: no key file with the copy instruction from the spec's КЛ1, `.unsupportedHost` with
  "<name> runs an older Supacode", `.failed`), and the scene: `Window("Remote Mac", id: WindowID.remoteClient)`
  with its own `Store`, opened by a File-menu item "Open Remote Mac…" published through
  `FocusedAction`, with a tooltip and a free hotkey.
- [ ] **Step 5: Run the suite; expect PASS. Build** (`make build-app`, logged).
- [ ] **Step 6: Live check.** Against the isolated host: the window opens, picks the test host,
  shows a worktree's first tab; `ls`, `vim`, `less`, mouse scroll, paste and Cyrillic work; the
  program gets no doubled answers (run `vim` and quit: no stray characters at the prompt); the
  local main window's sidebar and layouts are unchanged; quitting and reopening the app restores no
  remote tab and kills no local session.
- [ ] **Step 7: Commit** (`feat(remote-client): the Remote Mac window with one live tab`).

---

## Stage ЕТ4 — the sidebar, the layout mirror and the actions

### Task 10: The layout projection and the attached set (РЗ1, РЗ2, РЗ5)

**Files:**
- Create: `supacode/Features/RemoteClient/RemoteLayoutProjection.swift`
- Create: `supacode/Features/RemoteClient/RemoteAttachedSet.swift`
- Test: `supacodeTests/RemoteClientLayoutTests.swift`

**Interfaces:**
- Produces:

```swift
/// What the laptop chose in one worktree's layout; kept across pushed lists.
nonisolated struct RemoteLocalSelection: Equatable, Sendable {
  var activeGroupID: String?
  var focusedPaneID: [String: String] = [:]     // group id → pane id
  var zoomedPaneID: [String: String] = [:]      // group id → pane id
  var selectedTabID: [String: String] = [:]     // pane id → tab id
}
/// One worktree's layout as the window draws it.
nonisolated struct RemoteLayoutProjection: Equatable, Sendable {
  struct PaneView: Equatable, Identifiable, Sendable { let id: String; let tabs: [RemoteClientTab]; let selectedTabID: String? }
  struct GroupView: Equatable, Identifiable, Sendable {
    let id: String; let title: String; let tree: RemoteClientLayoutNode
    let focusedPaneID: String?; let zoomedPaneID: String?
  }
  let mode: String
  let groups: [GroupView]              // strip order; one in tabsPerSplit
  let activeGroupID: String?
  let panes: [String: PaneView]
  /// The tabs the window shows now: the selected tab of every pane of the active group
  /// (only the zoomed pane's when that group is zoomed), by content id.
  var visibleContentIDs: [String] { get }

  /// Seeds missing choices from the host's layout, drops choices whose tab, pane or group is
  /// gone, and returns the projection with the kept choices. A worktree without `layout`
  /// projects one group with one pane that holds every tab.
  static func project(_ worktree: RemoteClientWorktree, selection: inout RemoteLocalSelection) -> RemoteLayoutProjection
}

/// Which remote terminals stay attached (РЗ5).
nonisolated struct RemoteAttachedSet: Sendable {
  static let linger: Duration = .seconds(30)
  static let limit = 16
  struct Step: Equatable { var attach: [String]; var detach: [String] }
  /// `visible` in the window now, at `now`. Attaches new ones; detaches those hidden for `linger`
  /// or longer, and the least recently visible ones beyond `limit`.
  mutating func update(visible: [String], now: ContinuousClock.Instant) -> Step
  /// The instant the next hidden content's linger ends, to schedule the next `update`.
  var nextExpiry: ContinuousClock.Instant? { get }
}
```

Tab ids a pane names but `tabs` does not hold are skipped; a pane left with no tab is dropped from
its group's tree (its sibling takes the split's place). A group's `title` in `splitPerTab` is the
title of its focused pane's selected tab.

- [ ] **Step 1: Write the failing tests**

```swift
struct RemoteClientLayoutTests {
  // Fixtures: `worktree(layout:tabs:)` builds a RemoteClientWorktree.
  @Test func theFirstProjectionTakesTheHostsChoices() {
    // panes P1 [t1,t2 selected t2], P2 [t3]; group main focused P2 → selection seeded: P1→t2, P2→t3, focus P2
  }
  @Test func aLocalTabChoiceSurvivesAPushedList() {
    // selection P1→t1 (the host says t2) → projection.panes["P1"].selectedTabID == "t1" after project
  }
  @Test func aChoiceOfAClosedTabFallsBackToTheHosts() { /* selection P1→gone → seeded again from the host */ }
  @Test func aLocalZoomAndFocusAreKeptWhileThePaneExists() { }
  @Test func splitPerTabKeepsTheLocalActiveGroup() { /* host active G1, local G2 → activeGroupID == "G2" */ }
  @Test func aWorktreeWithoutLayoutIsOnePaneOfAllTabs() {
    // layout nil, tabs [t1,t2 focused] → one group, one pane, selected t2
  }
  @Test func unknownTabIdsAreSkippedAndAnEmptyPaneLeavesTheTree() { }
  @Test func visibleContentsAreTheSelectedTabsOfTheActiveGroup() { /* and only the zoomed pane's when zoomed */ }

  @Test func newVisibleContentsAttachAndHiddenOnesLingerThirtySeconds() {
    var set = RemoteAttachedSet()
    let start = ContinuousClock.now
    #expect(set.update(visible: ["a", "b"], now: start) == .init(attach: ["a", "b"], detach: []))
    #expect(set.update(visible: ["b"], now: start + .seconds(29)) == .init(attach: [], detach: []))
    #expect(set.nextExpiry == start + .seconds(59))
    #expect(set.update(visible: ["b"], now: start + .seconds(59)) == .init(attach: [], detach: ["a"]))
  }
  @Test func aContentShownAgainInTimeIsNotReattached() {
    var set = RemoteAttachedSet()
    let start = ContinuousClock.now
    _ = set.update(visible: ["a"], now: start)
    _ = set.update(visible: [], now: start + .seconds(5))
    #expect(set.update(visible: ["a"], now: start + .seconds(10)) == .init(attach: [], detach: []))
  }
  @Test func beyondSixteenTheLeastRecentlyVisibleGoes() {
    // show c0…c15 one after another (each hidden when the next shows), then c16 → detach == ["c0"]
  }
}
```

- [ ] **Step 2: Run `supacodeTests/RemoteClientLayoutTests`; expect compile failure.**
- [ ] **Step 3: Implement both types.**
- [ ] **Step 4: Run the suite; expect PASS.**
- [ ] **Step 5: Commit** (`feat(remote-client): layout projection with local selection, attached set`).

### Task 11: The feature — sidebar model, selection and actions (СЛ1–СЛ5, РЗ4, ПЗ4)

**Files:**
- Modify: `supacode/Features/RemoteClient/RemoteClientFeature.swift`
- Create: `supacode/Features/RemoteClient/RemoteSidebarModel.swift`
- Test: `supacodeTests/RemoteClientFeatureTests.swift`, `supacodeTests/RemoteClientSidebarTests.swift`

**Interfaces:**
- Consumes: Tasks 9, 10; `RemoteClientSessionClient` gains
  `request(_ t: String, _ fields: [String: String], _ ints: [String: Int], _ timeout: Duration) async throws -> [String: String]`,
  `setVisible(_ contentIDs: [String])` (drives `RemoteAttachedSet` in the session) and
  `fittingGrid(_ paneID: String) -> RemoteAutoResize.Grid?`.
- Produces:

```swift
nonisolated enum RemoteSidebarModel {
  struct Row: Equatable, Identifiable, Sendable {
    let id: String; let repositoryID: String; let name: String; let branch: String; let status: String
    let isWorking: Bool; let agents: [RemoteClientAgent]; let canDelete: Bool
  }
  enum Section: Equatable, Identifiable, Sendable {
    case highlight(kind: String, title: String, rows: [Row])
    case group(title: String, collapsed: Bool, repositories: [Repository])
    case repository(Repository)
    case loadFailure(repositoryID: String, message: String)
    var id: String { get }
  }
  struct Repository: Equatable, Identifiable, Sendable { let id: String; let name: String; let canCreateWorktree: Bool; let rows: [Row] }
  /// `list.sections` in order, rows by `rowIds`, unresolvable ids skipped; `filter` keeps rows whose
  /// repository name, worktree name, branch, title or a tab title contains it (case-insensitive).
  static func sections(_ list: RemoteClientList, filter: String) -> [Section]
}

// RemoteClientFeature.State, added
var filterText = ""
var selections: [String: RemoteLocalSelection] = [:]          // worktree id → local choices
var projection: RemoteLayoutProjection?                        // the selected worktree's
var newWorktree: NewWorktreePrompt?                            // { repositoryID, name }
var busyRequests: Set<String> = []                             // "worktree.new:<repo>", "worktree.delete:<id>", …
@Presents var alert: AlertState<Action.Alert>?

// RemoteClientFeature.Action, added
case filterChanged(String)
case tabSelected(paneID: String, tabID: String), paneFocused(String), zoomToggled(paneID: String), groupSelected(String)
case newTabTapped(paneID: String?), closeTabTapped(tabID: String), splitTapped(paneID: String, direction: SplitDirection)
case closePaneTapped(paneID: String)
case newWorktreeTapped(repositoryID: String), newWorktreeNameChanged(String), newWorktreeConfirmed, newWorktreeCancelled
case deleteWorktreeTapped(worktreeID: String), refreshTapped
case requestFinished(key: String, Result<[String: String], RemoteClientRequestError>)
case alert(PresentationAction<Alert>)       // Alert: confirmCloseTab(String), confirmClosePane(String), confirmDeleteWorktree(String)
```

Timeouts (the protocol's client contract): `worktree.new` 320 s, `worktree.delete` 310 s,
`worktrees.refresh` 70 s, `tab.new` / `pane.split` 15 s, `tab.close` / `pane.close` 10 s.

Rules: selection actions change only `selections` and re-project; they send nothing.
`closeTabTapped` of a tab whose `working` is true, and every `closePaneTapped` and
`deleteWorktreeTapped`, first present the confirmation alert; the confirmed action sends the
request. `newTabTapped` sends `tab.new` with the worktree, the optional `paneId`, and the pane's
fitting `cols` / `rows`. A successful `tab.new`, `pane.split` or `worktree.new` selects the new tab
locally when the next `list` holds it. A host error shows its `message` in an alert as is;
`connectionLost` and `timeout` of a `worktree.new` show "Connection lost; the worktree may still
appear in the list", of a `worktree.delete` "Connection lost; the worktree may still disappear from
the list", and nothing is retried. `listChanged` re-projects, keeps `selectedWorktreeID` while that
worktree exists, and calls `setVisible(projection.visibleContentIDs)`.

- [ ] **Step 1: Write the failing tests**

```swift
struct RemoteClientSidebarTests {
  @Test func sectionsFollowTheHostsOrder() { /* active, pinned, group, repository as given */ }
  @Test func repositoryRowsComeFromRowIdsWithoutHoistedOnes() { }
  @Test func aPendingRowIdThatDoesNotResolveIsSkipped() { /* "pending:x" */ }
  @Test func loadFailuresBecomeSections() { }
  @Test func theFilterMatchesRepoWorktreeBranchAndTabTitle() { /* and drops repositories left with no row */ }
  @Test func anUnknownSectionKindIsSkipped() { }
}
```

```swift
// RemoteClientFeatureTests, added
@Test func selectingATabIsLocalAndSendsNothing() async { /* selections updated; request never called */ }
@Test func aPushedListKeepsTheLocalTabChoice() async { }
@Test func closingAWorkingTabAsksFirst() async { /* alert presented; confirm → request("tab.close", ["tabId": …]) */ }
@Test func closingAnIdleTabSendsAtOnce() async { }
@Test func closingAPaneAlwaysAsks() async { }
@Test func aSplitSendsTheTwoWayDirection() async { /* .vertical → ["paneId": …, "direction": "vertical"] */ }
@Test func aNewTabCarriesThePaneAndItsGrid() async { /* ints == ["cols": 120, "rows": 40] */ }
@Test func aNewWorktreeNeedsANameAndSendsItTrimmed() async { /* blank name: confirm does nothing */ }
@Test func aDirtyDeleteShowsTheHostsMessage() async { /* code worktree_dirty → alert with the message as is */ }
@Test func aLostConnectionDuringCreationSaysTheWorktreeMayStillAppear() async { /* and request is called once */ }
@Test func aRequestInFlightDisablesItsButton() async { /* busyRequests holds the key until requestFinished */ }
@Test func theVisibleSetFollowsTheSelectedWorktreeAndTabs() async { /* setVisible called with the selected tabs */ }
@Test func aSelectedWorktreeThatVanishesFallsBackToTheFirst() async { }
```

- [ ] **Step 2: Run both suites; expect compile failure.**
- [ ] **Step 3: Implement `RemoteSidebarModel`, then the reducer additions and the session's
  `setVisible` (it runs `RemoteAttachedSet.update`, makes or tears down `RemoteTerminalContent`s, and
  schedules the next update at `nextExpiry` on the clock).**
- [ ] **Step 4: Run both suites; expect PASS.**
- [ ] **Step 5: Commit** (`feat(remote-client): sidebar model, local selection and remote actions`).

### Task 12: The views — sidebar, tab strips, splits, menu actions (ОБ1–ОБ3)

**Files:**
- Create: `supacode/Features/RemoteClient/Views/RemoteSidebarView.swift`
- Create: `supacode/Features/RemoteClient/Views/RemoteLayoutView.swift`
- Create: `supacode/Features/RemoteClient/Views/RemoteTabStripView.swift`
- Modify: `supacode/Features/RemoteClient/Views/RemoteClientWindowView.swift`
- Modify: `supacode/Features/Terminal/Views/LayoutContentView.swift` (make `ContentHostView` usable from this folder: drop `private`; no behaviour change)

**Interfaces:**
- Consumes: `RemoteSidebarModel.sections`, `RemoteLayoutProjection`, the actions of Task 11,
  `SplitView` (plain values; reused as is), `ContentHostView(contentID:runtime:epoch:)` with the
  session's own `ContentRuntime`.

The remote window gets its own strip and layout views instead of `PaneTabStrip` /
`LayoutContentView`, because those take a `StoreOf<LayoutFeature>`; this keeps `LayoutFeature`
untouched (the spec's РЗ6 allows it).

- [ ] **Step 1: Sidebar.** A `List` of `RemoteSidebarModel.sections` with the filter field on top
  (the local sidebar's `SidebarFilterField`: it takes `query: Binding<String>`, a
  `FocusState<Bool>.Binding`, the "Filter Sidebar" `AppShortcut?` and `onEscape`, all of which the
  window view can supply). A row shows name, branch, the status glyph for `main` /
  `pinned`, a working indicator and one badge per agent with its activity. Context menus and header
  buttons: "New Worktree…" (when `canCreateWorktree`), "Delete Worktree…" (when `canDelete`),
  "Refresh Worktrees" (when `list.canRefreshWorktrees`), each disabled while its key is in
  `busyRequests`, each with a tooltip. Reading per-row data from the model, never from the store in
  a row's body, keeps a pushed list from invalidating every row.
- [ ] **Step 2: Layout.** `RemoteLayoutView` draws the active group's tree recursively with
  `SplitView` (ratio from the node; `onResize` and `onEqualize` do nothing — divider drag is ПС6),
  each leaf a `RemoteTabStripView` above the selected tab's `ContentHostView`; in `splitPerTab` a
  top strip of groups (titles from the projection). A zoomed group draws only the zoomed pane. A tab
  whose content's `phase` is `.ended` shows "This terminal ended on <Mac name>" in place of the
  surface. An unfocused pane gets the same dimming overlay the local layout uses.
- [ ] **Step 3: Strip.** One button per tab (title, working shimmer, read-only lock, agent badge),
  a close button on hover, "+" for a new tab, and a pane menu: Split Right (`.horizontal`), Split
  Down (`.vertical`), Zoom, Close Pane. Buttons, not tap gestures; every one with a tooltip that
  names its hotkey.
- [ ] **Step 4: Menu actions (ПЗ4).** While the remote window is key it publishes the focused
  actions the terminal menu reads for New Tab, Close Tab, Split Right, Split Down, Toggle Zoom, Next
  / Previous Tab and Select Tab 1–9, each through `.focusedSceneAction(_:enabled:token:perform:)`
  with a token made of the selected worktree id, the focused pane id and the selected tab id; each
  sends the matching `RemoteClientFeature` action.
- [ ] **Step 5: Build** (`make build-app`, logged) **and lint the new files**
  (`DEVELOPER_DIR="$(./scripts/select-developer-dir.sh)" mise exec -- swiftlint lint --quiet --config .swiftlint.yml supacode/Features/RemoteClient`).
- [ ] **Step 6: Live check, with screenshots kept in `./tmp/claude-logs/`.** Against the isolated
  host with two repositories, a pinned worktree, an agent tab and a split:
  1. The sidebar matches the host's sidebar section by section; the filter narrows it.
  2. The splits match the host's; both layout modes render (switch the host's Terminal Layout
     setting and wait for the pushed list).
  3. ⌘T, ⌘W on an idle and on a working tab, Split Right, Split Down and Close Pane change the host's
     layout and then the window; the host shows no confirmation.
  4. A tab made on the host appears in the window within about a second without stealing the
     selected tab.
  5. New Worktree, Delete Worktree on a clean and on a dirty worktree, Refresh.
  6. Resizing the window: each visible tab follows after the drag ends; the host's own pane shows
     the laptop's grid; closing the remote window gives the host its own size back within about 32 s.
  7. The local main window still works while the remote one is open; its menu commands act on it
     when it is key.
- [ ] **Step 7: Commit** (`feat(remote-client): sidebar, tab strips, splits and menu actions`).

---

## Stage ЕТ5 — the banner, notifications and docs

### Task 13: No connection (БН1–БН4)

**Files:**
- Create: `supacode/Features/RemoteClient/RemoteConnectionBanner.swift`
- Create: `supacode/Features/RemoteClient/Views/RemoteConnectionBannerView.swift`
- Modify: `supacode/Features/RemoteClient/RemoteTerminalContent.swift` (its `toolbar`)
- Modify: `supacode/Features/RemoteClient/Views/RemoteSidebarView.swift`, `RemoteClientWindowView.swift`
- Test: `supacodeTests/RemoteClientBannerTests.swift`, `supacodeTests/RemoteClientConnectionTests.swift`

**Interfaces:**
- Produces:

```swift
nonisolated enum RemoteConnectionBanner {
  /// The text above a remote terminal; nil while the terminal is live.
  static func text(status: RemoteClientStatus, isAttached: Bool, hostName: String?) -> String?
}
```

Texts, with `<Mac>` = the host name or "the Mac": `.connecting` → "Connecting to <Mac>…";
`.hostOffline` → "<Mac> is offline."; `.online` and not yet attached → "Connecting to <Mac>…";
`.online` and attached → nil; `.failed`, `.idle`, `.choosingHost`, `.unsupportedHost` →
"No connection to <Mac>. Typing is not sent."; `.connecting` after a terminal was attached before
→ "No connection to <Mac>. Typing is not sent.".

- [ ] **Step 1: Write the failing tests**

```swift
struct RemoteClientBannerTests {
  @Test func aLiveTerminalHasNoBanner() { #expect(RemoteConnectionBanner.text(status: .online(.lan), isAttached: true, hostName: "Office Mac") == nil) }
  @Test func anOfflineMacIsNamed() { #expect(RemoteConnectionBanner.text(status: .hostOffline, isAttached: false, hostName: "Office Mac") == "Office Mac is offline.") }
  @Test func aLostConnectionSaysTypingIsNotSent() {
    #expect(RemoteConnectionBanner.text(status: .failed("x"), isAttached: false, hostName: nil) == "No connection to the Mac. Typing is not sent.")
  }
  @Test func reattachingShowsConnecting() { #expect(RemoteConnectionBanner.text(status: .online(.relay), isAttached: false, hostName: "A") == "Connecting to A…") }
}
```

```swift
// RemoteClientConnectionTests, added                                            // РФ5
@Test func inputTypedWhileOfflineIsNeverSentLater() async {
  // attached and online; the relay socket closes; sendInput(…) three times → false each time;
  // reconnect, hello, list, attach → the sent frames hold no "input"
}
```

- [ ] **Step 2: Run both suites; expect the banner suite not to compile and the new connection
  test to pass or fail on its own merits** (Task 6 already drops input while not online; a failure
  here is a bug to fix now).
- [ ] **Step 3: Implement** `RemoteConnectionBanner`, the banner view (system colors, Dynamic
  Type, an icon and one line), and expose it as `RemoteTerminalContent.toolbar`
  (`TabContentToolbar`), so it docks above the terminal and reserves no space when nil. Dim the
  sidebar and show the same text under the window title while the status is not `.online` (БН3).
- [ ] **Step 4: Run both suites; expect PASS. Build.**
- [ ] **Step 5: Live check.** Turn Wi-Fi off: within about 35 s (the 30 s ping) the banner shows
  over every remote terminal and the sidebar dims; type a few characters; turn Wi-Fi on: the banner
  goes at the first `attached`, the screen redraws once, the typed characters never arrive, and the
  terminal's size on the host did not change in between.
- [ ] **Step 6: Commit** (`feat(remote-client): a banner above the terminal when there is no connection`).

### Task 14: Notifications (ИВ1–ИВ4)

**Files:**
- Modify: `supacode/Features/RemoteClient/RemoteClientFeature.swift`
- Create: `supacode/Features/RemoteClient/RemoteClientNotifier.swift`
- Test: `supacodeTests/RemoteClientFeatureTests.swift`

**Interfaces:**
- Consumes: `RemoteAwaitingTracker` (Task 4); the app's existing system-notification path (the
  dependency `AppFeature` uses to post and remove notifications; reuse it, do not add a second
  `UNUserNotificationCenter` wrapper).
- Produces:

```swift
// RemoteClientFeature.State
var awaiting = RemoteAwaitingTracker()
var isKeyWindow = false
// RemoteClientFeature.Action
case windowKeyChanged(Bool)
case notificationOpened(worktreeID: String, contentID: String)

nonisolated enum RemoteClientNotifier {
  /// Stable per Mac and tab, so a new one replaces the old: "remote:<hostId>:<contentId>".
  static func identifier(hostID: String?, contentID: String) -> String
  static func title(hostName: String?) -> String                       // "<Mac> — agent is waiting"
  static func body(_ tab: RemoteAwaitingTab) -> String                 // "<worktree> · <tab title>"
  /// Not when the tab is visible in the key remote window.
  static func shouldPost(_ tab: RemoteAwaitingTab, isKeyWindow: Bool, visibleContentIDs: [String]) -> Bool
}
```

`listChanged` runs `awaiting.update`: each `started` tab for which `shouldPost` holds is posted;
each `ended` id is removed. `hostPicked` and `windowClosed` run `awaiting.reset()` and remove what
it returns. `notificationOpened` brings the remote window forward, selects that worktree and, in
its selection, the pane and tab that hold that content. A remote BEL rings as the laptop's Ghostty
settings say (the surface does that by itself); OSC 9 / 777 from the remote program post nothing:
`RemoteTerminalContent` installs no desktop-notification handler on its surface's bridge.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func anAgentThatStartsToWaitPostsOnce() async { /* two lists: idle → awaitingInput → one post with the id "remote:a:t1" */ }
@Test func theFirstListPostsNothing() async { }
@Test func aTabVisibleInTheKeyWindowPostsNothing() async { /* isKeyWindow true and the tab visible */ }
@Test func aTabThatStopsWaitingRemovesItsNotification() async { }
@Test func switchingTheMacRemovesEveryNotification() async { }
@Test func openingANotificationSelectsItsWorktreeAndTab() async { /* selections[worktree].selectedTabID[pane] == tab */ }
@Test func theNotifierNamesTheMacAndTheTab() {
  #expect(RemoteClientNotifier.title(hostName: "Office Mac") == "Office Mac — agent is waiting")
  #expect(RemoteClientNotifier.identifier(hostID: "a", contentID: "t1") == "remote:a:t1")
}
```

- [ ] **Step 2: Run `supacodeTests/RemoteClientFeatureTests`; expect compile failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the suite; expect PASS. Build.**
- [ ] **Step 5: Live check.** With the remote window behind another app, make an agent on the host
  wait for input: one notification with the Mac's name; clicking it brings the remote window forward
  on that tab; the local main window's notification list and sidebar show nothing new.
- [ ] **Step 6: Commit** (`feat(remote-client): agent-is-waiting notifications from the remote Mac`).

### Task 15: Docs, the full run and the end-to-end check

**Files:**
- Modify: `docs/fork.md` (new section "Remote Client Window": what it is, the fork-only folder
  `supacode/Features/RemoteClient/`, `supacode-cli/Commands/RemotePipeCommand.swift`, each upstream
  file touched — `supacodeApp.swift`, `WindowID.swift`, `SupacodeCLI.swift`, `LayoutContentView.swift`,
  `GhosttySurfaceView.swift`, `TabContent.swift` — and the suites that guard it)
- Modify: `docs/remote-access.md` (new section "Use another Mac from Supacode": the key file on
  the laptop, "Open Remote Mac…", picking a Mac, what the banner means)
- Modify: `docs/plans/2026-11-17-remote-client-design.md` (status → implemented; the outcomes of
  the two spikes in "Not confirmed")

- [ ] **Step 1: Write the three doc changes.** No relay URL, key, account id or real Mac name in
  any of them; examples use `relay.example.com`.
- [ ] **Step 2: Full test run** (`make test`, logged; rerun once on a known flaky test).
- [ ] **Step 3: Build and install** (`make build-app`, then `make install-dev-build`, both logged).
- [ ] **Step 4: End-to-end check against the owner's second Mac** (after it runs a build with the
  host plan): the whole list of Task 12 Step 6, the Wi-Fi check of Task 13, the notification check
  of Task 14, and a LAN ⇄ relay switch (leave and rejoin the Mac's network) with two tabs open: the
  title shows the path, each tab redraws once and keeps its size. The phone still works against the
  same Mac at the same time. Record each result.
- [ ] **Step 5: Self-review of the whole branch** with the `self-review` skill: collect findings,
  revalidate each against the source, fix the confirmed ones, report all.
- [ ] **Step 6: Commit** (`docs(remote-client): fork notes and how to use another Mac`).

## Stage ЕТ6 — several remote Macs at once (ПС8)

Added by the owner on 2026-11-19, after ЕТ5. Only the first half of ПС8: one window per Mac.
Notifications while no remote window is open stay out (КЛ6 holds per window).

### Task 16: One Remote Mac window per Mac

**Files:**
- Modify: `supacode/App/supacodeApp.swift` (the `Window` scene becomes a `WindowGroup` keyed by the
  Mac)
- Modify: `supacode/Features/RemoteClient/RemoteClientCommands.swift`,
  `RemoteClientFeature.swift`, `RemoteClientSession.swift`, `Views/RemoteClientWindowView.swift`
- Modify: `supacode/Features/RemoteClient/RemoteClientNotifier.swift` (the window that a
  notification opens)
- Test: `supacodeTests/RemoteClientFeatureTests.swift`, `supacodeTests/RemoteClientSessionTests.swift`

**Interfaces:**
- Produces:

```swift
/// The value a remote window is opened for. `nil` hostID: a new window that shows the picker.
nonisolated struct RemoteClientWindowValue: Codable, Hashable, Sendable { var hostID: String? }
```

Rules:
- `WindowGroup("Remote Mac", for: RemoteClientWindowValue.self)`. "Open Remote Mac…" (⌃⌘O) opens a
  new window with `hostID: nil`; its picker lists the Macs that no other remote window shows, and
  a Mac that is already open is brought forward instead of opened twice.
- Each window owns its own `RemoteClientSession` (connection, contents, `ContentRuntime`). The pipe
  server is shared by every window of the app and routes by content id; content ids are keyed by
  host id too, so two Macs with the same content id never collide.
- The selected Mac belongs to the window (the window's value), not to one `@Shared` value. The
  last selection is still remembered for the next "Open Remote Mac…" when only one window is open,
  so the one-Mac flow does not change.
- Switching the Mac inside a window (МХ3) changes that window's value; a Mac already open in another
  window is not offered.
- Every window has its own awaiting tracker (ИВ1–ИВ3); a notification's identifier keeps the host
  id (`remote:<hostId>:<contentId>`), and clicking it brings forward the window of that Mac, or
  opens one.
- Closing a window disconnects only that Mac (КЛ6). Quitting the app closes every session.
- Relay limits: one client connection per window. Four windows are four connections; the relay's 20
  connects per IP per minute and the reconnect backoff (Task 6) keep within it.

- [ ] **Step 1: Write the failing tests:** two sessions for two hosts get separate connections and
  separate lists; a content id that both Macs use maps to two contents; opening a Mac that a window
  already shows focuses that window; the picker leaves out Macs shown in other windows; closing one
  window stops only its session; a notification for host B brings B's window forward.
- [ ] **Step 2: Run the suites; expect failures.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run every `RemoteClient*Tests`; expect PASS. Build** (`make build-app`, logged).
- [ ] **Step 5: Live check:** with the mock host (it serves Office Mac and Home Mac), open both Macs
  in two windows, type in both, resize both, close one: the other keeps working; the mock host log
  shows two client connections and one closing.
- [ ] **Step 6: Commit** (`feat(remote-client): one Remote Mac window per Mac`).

## After this plan

Tell the owner what `supacode-remote` can pick up now: `tools/mock-host.mjs` with the new
messages; the phone and the web app need nothing until they use them. The plan and the spec move to
`docs/plans/done/` only when the owner says the feature is done.
