# Remote Client — Host And Protocol (ЕТ1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Supacode as a host answers the new protocol messages a Supacode client needs: several
attachments per connection, the layout in `list`, pushed `list`, layout actions and a held size.

**Architecture:** Every rule is a small pure type in `supacode/Features/RemoteAccess/` with its own
unit tests; `RemoteHostRouter` only wires them to sockets, and `RemoteSnapshotSource` reads and
changes app state through the existing terminal manager and layout actions. The held size keeps its
owner in the router and its grid on the terminal content, which pins every surface it has.

**Tech Stack:** Swift 6, TCA, Swift Testing with `TestClock`, GhosttyKit, Node (`phone-sim.mjs`).

**Spec:** `docs/plans/2026-11-17-remote-client-design.md` (sections "Protocol changes" ПТ0–ПТ6 and
"Host changes" ХС1–ХС7). The second plan, `docs/plans/2026-11-17-remote-client-app.md`, builds the
client on top of this one.

## Global Constraints

- All protocol changes are additive; `v` stays `1`. A client that sends none of the new fields gets
  exactly today's behaviour. No change under `remote-relay/src/`.
- No new state and no new actions in `LayoutFeature`. Use `LayoutFeature.Action.closeTab(id:)`,
  `closePane(id:)` and `TerminalClient.Command.splitPane` / `.createTab`.
- No `Task.sleep` in tests; time comes from the router's injected `clock` and a `TestClock`.
- Every main-actor class declares `nonisolated deinit {}`. Log only through `SupaLogger`
  (`routerLogger`), never a key, the relay URL or a host name.
- No top-level free functions: pure helpers are `static` on a caseless `enum` or a struct.
- Code that lists a layout's terminals reads the flat `PaneLayout.panes`; it never walks only the
  active tree (`.agent-memory/split-per-tab-invariants.md`).
- Test targets: `RemoteAccess*Tests` are in `supacodeTests`; `Ghostty*` and `TerminalRendering*`
  suites are in `supacodeTerminalTests` / `supacodeTests` as their file name's glob decides
  (`Project.swift`). Test files import every module whose members they use.
- Commits: one per task, only the task's files (`git add <paths>`, never `git add .`), no co-author
  line. Run `mise exec -- swift-format --in-place --configuration ./.swift-format.json <files>` on
  the task's Swift files before the commit.

**Run one suite** (replace `<Target>/<Suite>`; a single test needs its `()`):

```bash
mkdir -p ./tmp/claude-logs && LOG=./tmp/claude-logs/test-$(date +%Y%m%d-%H%M%S).log && DEVELOPER_DIR="$(./scripts/select-developer-dir.sh)" xcodebuild test -workspace supacode.xcworkspace -scheme supacode-tests -destination platform=macOS -derivedDataPath .build/DerivedData -only-testing:<Target>/<Suite> > "$LOG" 2>&1; command grep -cE '✔|passed' "$LOG"; command tail -n 30 "$LOG"
```

A run that executed zero tests still prints `** TEST SUCCEEDED **`: check that the count of passed
tests is not 0.

## Review Focus

- **РФ1.** A connection attached to tabs A and B detaches A while a resize of B is pending: B's
  wait and B's stream go on; only A stops. Pinned in Task 4.
- **РФ2.** A client that sends `attach` without `keep` (the phone) on a connection that kept two
  tabs: both stop and their holds release at once. Pinned in Tasks 4 and 9.
- **РФ3.** A `splitPerTab` layout with a parked group whose tree is zoomed: `layout` lists every
  pane of every group, and `zoomedPaneId` sits on the parked group. Pinned in Task 5.
- **РФ4.** A tab whose title changes ten times a second while nothing else changes: at most one
  pushed `list` per 2 s, and a structural change in between still goes out within 250 ms. Pinned in
  Task 6.
- **РФ5.** A held tab is hibernated and woken, or its pane changes size: the PTY keeps the held
  grid; after the owner's connection drops the grid stays 30 s, and a new connection that asks for
  the same size in that time causes no size change. Pinned in Tasks 8 and 9.

---

### Task 1: The protocol document

**Files:**
- Modify: `docs/remote-access-protocol.md`

**Interfaces:**
- Produces: the wire contract every later task and the client plan implement.

- [ ] **Step 1: Write the new sections.** Copy the contract from the spec, sections ПТ0–ПТ4 and
  ПТ6, into the protocol document in its own style (English, present tense):
  - `hello`: the `caps` array and its seven values.
  - `attach / detach`: `keep`, the limit of 16 and `attach_limit`, re-attach, `detach` of one
    content. Replace the sentence "A client may attach one content at a time; attaching another
    detaches the first." with the `keep` rule.
  - `list`: the `layout` object (`mode`, `activeGroupId`, `groups`, `tree`, `zoomedPaneId`,
    `panes`), with the JSON example from the spec.
  - New `### watch`: request, reply, the 250 ms rule, the 2 s rule for title-only changes, the end
    of a watch.
  - `resize`: "for any content the connection is attached to"; the `hold` field with every bullet
    of ПТ6 (no Ctrl+L, held, one owner, release, the 30 s, the client rule).
  - `tab.new`: optional `paneId`; an unknown or malformed `paneId` is ignored and logged.
  - New `### tab.close`, `### pane.split`, `### pane.close` with their replies and error codes.
  - `errors`: add `attach_limit`, `tab_invalid`, `tab_failed`, `pane_invalid`, `pane_failed`.
  - The decoder rule: `keep`, `on`, `hold` (booleans), `tabId`, `paneId` (strings) are strict;
    `direction` is lenient.

- [ ] **Step 2: Check it against the spec.** Read both side by side: every field name, limit
  (16, 250 ms, 2 s, 30 s, 10 s) and error code in the spec is in the document with the same value.

- [ ] **Step 3: Commit**

```bash
git add docs/remote-access-protocol.md
git commit -m "docs(remote): protocol — caps, attach keep, layout, watch, layout actions, held size"
```

### Task 2: Inbound fields, capabilities, and the test host id

**Files:**
- Modify: `supacode/Features/RemoteAccess/RemoteProtocol.swift`
- Modify: `supacode/Features/RemoteAccess/RemoteRelayConnection.swift` (`RemoteAccessConfig`)
- Modify: `docs/remote-access.md` (Troubleshooting, "A second Supacode for tests")
- Test: `supacodeTests/RemoteAccessProtocolTests.swift`, `supacodeTests/RemoteAccessConfigHostTests.swift`

**Interfaces:**
- Produces:
  - `RemoteInboundMessage` fields `keep: Bool?`, `on: Bool?`, `hold: Bool?`, `tabId: String?`,
    `paneId: String?`, `direction: RemoteLenientString?`.
  - `nonisolated enum RemoteCapability { static let all: [String] }` =
    `["attach.keep","watch","layout","tab.close","pane.split","pane.close","resize.hold"]`.
  - `RemoteHelloMessage.caps: [String]`, default `RemoteCapability.all`.
  - `RemoteAccessConfig.hostIDVariable = "SUPACODE_REMOTE_HOST_ID"` and
    `static func hostID(hardwareUUID: String?, environment: [String: String]) -> String?`.

- [ ] **Step 1: Write the failing tests**

```swift
// RemoteAccessProtocolTests
@Test func inboundDecodesTheNewFields() throws {
  let attach = try #require(RemoteJSON.decodeInbound(Data(#"{"t":"attach","contentId":"C","keep":true}"#.utf8)))
  #expect(attach.keep == true)
  let split = try #require(
    RemoteJSON.decodeInbound(Data(#"{"t":"pane.split","id":7,"paneId":"P","direction":"vertical"}"#.utf8)))
  #expect(split.paneId == "P")
  #expect(split.direction?.value == "vertical")
  let resize = try #require(
    RemoteJSON.decodeInbound(Data(#"{"t":"resize","contentId":"C","cols":80,"rows":24,"hold":true}"#.utf8)))
  #expect(resize.hold == true)
}

@Test func aStrictNewFieldOfTheWrongTypeDropsTheMessage() {
  #expect(RemoteJSON.decodeInbound(Data(#"{"t":"attach","contentId":"C","keep":"yes"}"#.utf8)) == nil)
  #expect(RemoteJSON.decodeInbound(Data(#"{"t":"watch","on":1}"#.utf8)) == nil)
  #expect(RemoteJSON.decodeInbound(Data(#"{"t":"tab.close","tabId":5}"#.utf8)) == nil)
}

@Test func aLenientDirectionOfTheWrongTypeStillDecodes() throws {
  let split = try #require(RemoteJSON.decodeInbound(Data(#"{"t":"pane.split","paneId":"P","direction":3}"#.utf8)))
  #expect(split.direction?.value == nil)
}

@Test func helloCarriesTheCapabilities() throws {
  let data = RemoteJSON.encode(RemoteHelloMessage(host: "Mac", hostId: nil, lan: nil, app: nil))
  let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(json["caps"] as? [String] == [
    "attach.keep", "watch", "layout", "tab.close", "pane.split", "pane.close", "resize.hold",
  ])
}
```

```swift
// RemoteAccessConfigHostTests
@Test func theTestHostIDReplacesTheDerivedOneOnlyWithForcedHosting() {
  let derived = RemoteAccessConfig.hostID(hardwareUUID: "U")
  #expect(RemoteAccessConfig.hostID(
    hardwareUUID: "U", environment: ["SUPACODE_REMOTE_ACCESS": "1", "SUPACODE_REMOTE_HOST_ID": "test-mac_2"]) == "test-mac_2")
  #expect(RemoteAccessConfig.hostID(hardwareUUID: "U", environment: ["SUPACODE_REMOTE_HOST_ID": "test-mac_2"]) == derived)
  #expect(RemoteAccessConfig.hostID(
    hardwareUUID: "U", environment: ["SUPACODE_REMOTE_ACCESS": "0", "SUPACODE_REMOTE_HOST_ID": "test-mac_2"]) == derived)
}

@Test func anInvalidTestHostIDIsIgnored() {
  let derived = RemoteAccessConfig.hostID(hardwareUUID: "U")
  for bad in ["", "has space", "ъ", String(repeating: "a", count: 65)] {
    #expect(RemoteAccessConfig.hostID(
      hardwareUUID: "U", environment: ["SUPACODE_REMOTE_ACCESS": "1", "SUPACODE_REMOTE_HOST_ID": bad]) == derived)
  }
}
```

`RemoteHelloMessage` is compared by value in `RemoteAccessHelloWaitTests`; a default `caps`
keeps those tests as they are.

- [ ] **Step 2: Run both suites; expect compile failures** (`keep`, `caps`, `hostID(hardwareUUID:environment:)` unknown).

- [ ] **Step 3: Implement.** Add the six fields to `RemoteInboundMessage`; add `RemoteCapability`
  and `caps` (always encoded). In `RemoteAccessConfig` add `hostIDVariable` and
  `hostID(hardwareUUID:environment:)`: the override applies only when
  `environment[overrideVariable] == "1"` and the value matches `^[A-Za-z0-9_-]{1,64}$`; otherwise it
  returns `hostID(hardwareUUID:)`. `currentHostID` calls it with
  `ProcessInfo.processInfo.environment`. An ignored non-empty value logs one line without the value.

- [ ] **Step 4: Document the variable** in `docs/remote-access.md`, in the "A second Supacode for
  tests" entry: `SUPACODE_REMOTE_HOST_ID=<id>` with `SUPACODE_REMOTE_ACCESS=1` gives that copy its
  own place on the relay, so it does not take the installed app's slot.

- [ ] **Step 5: Run both suites; expect PASS.**

- [ ] **Step 6: Commit**

```bash
git add supacode/Features/RemoteAccess/RemoteProtocol.swift supacode/Features/RemoteAccess/RemoteRelayConnection.swift docs/remote-access.md supacodeTests/RemoteAccessProtocolTests.swift supacodeTests/RemoteAccessConfigHostTests.swift
git commit -m "feat(remote): new inbound fields, hello caps and a test host id (ПТ0, ХС5)"
```

### Task 3: The router keeps a set of attachments (no behaviour change)

**Files:**
- Modify: `supacode/Features/RemoteAccess/RemoteHostRouter.swift`
- Modify: `supacode/Features/RemoteAccess/RemoteProtocol.swift` (`RemoteResizeWaits`, `RemoteResizeRequest`)
- Test: `supacodeTests/RemoteAccessProtocolTests.swift`, `supacodeTests/RemoteAccessResizeTests.swift`

**Interfaces:**
- Produces:
  - Router state `clients: [String: [UUID: Attachment]]` (a key means "known connection") and
    `sentGrids: [String: [UUID: SentGrid]]`.
  - `RemoteResizeWaits.cancel(connID: String, contentID: UUID)`: cancels the wait for that content
    only when that connection asked for it.
  - `RemoteResizeRequest.resolve(_ message: RemoteInboundMessage, attached: Set<UUID>) -> Result<Self, Ignored>`.
  - Router helpers `detach(connID: String, contentID: UUID)` and `detachAll(connID: String)`.

This task changes shape only. `attach` still calls `detachAll(connID:)` first, so a connection
still holds one attachment and every existing suite stays green.

- [ ] **Step 1: Write the failing tests**

```swift
// RemoteAccessProtocolTests
@Test func resizeResolvesForAnyAttachedContent() {
  let first = UUID(), second = UUID()
  let message = RemoteInboundMessage(
    t: "resize", contentId: second.uuidString, cols: RemoteLenientInt(100), rows: RemoteLenientInt(30))
  let resolved = RemoteResizeRequest.resolve(message, attached: [first, second])
  #expect(resolved == .success(RemoteResizeRequest(contentID: second, columns: 100, rows: 30)))
  #expect(RemoteResizeRequest.resolve(message, attached: [first]) == .failure(.notAttached))
  #expect(RemoteResizeRequest.resolve(message, attached: []) == .failure(.notAttached))
}

@Test func aResizeWaitIsCancelledOnlyForItsOwnContentAndConnection() {
  var waits = RemoteResizeWaits()
  let tabA = UUID(), tabB = UUID()
  waits.start(contentID: tabA, connID: "c1", token: UUID(), task: Task {})
  waits.start(contentID: tabB, connID: "c1", token: UUID(), task: Task {})
  waits.cancel(connID: "c2", contentID: tabA)
  #expect(waits.pendingConnID(contentID: tabA) == "c1")
  waits.cancel(connID: "c1", contentID: tabA)
  #expect(waits.pendingConnID(contentID: tabA) == nil)
  #expect(waits.pendingConnID(contentID: tabB) == "c1")
}
```

- [ ] **Step 2: Run `supacodeTests/RemoteAccessProtocolTests`; expect compile failures.**

- [ ] **Step 3: Implement the two pure changes**, then update the existing callers of
  `resolve(_:attached:)` in the tests (`attached: id` becomes `attached: [id]`, `nil` becomes `[]`).

- [ ] **Step 4: Reshape the router.** Every `clients[connID]` read of the form
  `case .some(.some(let attachment))` becomes a lookup by content id; `clients[connID] = .some(nil)`
  becomes `clients[connID] = clients[connID] ?? [:]`. Touch each of these and keep its meaning:
  `lanOpened`, `lanClosed`, `receiveDirect` (`conn.close`, `hello`), `attach`, `sendSizeIfChanged`,
  `streamClosed`, `isCurrent` (now `clients[connID]?[contentID]?.stream === stream`),
  `detachRequested` (a `contentId` names the content; none means all), `detach`, `forgetAttachment`,
  `input`, `resize` (passes `Set(clients[connID]?.keys ?? [])`), `finishResize`, `writeOnce`,
  `dropAllClients`, `suggest`. `detach(connID:contentID:)` cancels the resize wait with
  `cancel(connID:contentID:)`; `detachAll(connID:)` loops over it.

- [ ] **Step 5: Run the gate.** Run `supacodeTests/RemoteAccessProtocolTests`,
  `RemoteAccessResizeTests`, `RemoteAccessHelloWaitTests`, `RemoteAccessTabNewTests`,
  `RemoteAccessWorktreeNewTests`, `RemoteAccessWorktreeDeleteTests`, `RemoteAccessLANServerTests`.
  Expect all PASS with no test edited except the `attached:` argument.

- [ ] **Step 6: Commit**

```bash
git add supacode/Features/RemoteAccess/RemoteHostRouter.swift supacode/Features/RemoteAccess/RemoteProtocol.swift supacodeTests/RemoteAccessProtocolTests.swift supacodeTests/RemoteAccessResizeTests.swift
git commit -m "refactor(remote): the router keeps a set of attachments per connection"
```

### Task 4: `attach` with `keep`, the limit, and `detach` of one content (ПТ1)

**Files:**
- Create: `supacode/Features/RemoteAccess/RemoteAttachPolicy.swift`
- Modify: `supacode/Features/RemoteAccess/RemoteHostRouter.swift` (`attach`, `detachRequested`)
- Test: `supacodeTests/RemoteAccessAttachTests.swift` (new)

**Interfaces:**
- Consumes: `RemoteInboundMessage.keep`, the router helpers of Task 3.
- Produces:

```swift
nonisolated enum RemoteAttachPolicy {
  static let limit = 16
  enum Decision: Equatable {
    /// Start the stream after stopping these attachments of the same connection.
    case attach(detaching: Set<UUID>)
    case limitReached
  }
  static func decide(attached: Set<UUID>, contentID: UUID, keep: Bool) -> Decision
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct RemoteAccessAttachTests {
  @Test func withoutKeepEveryOtherAttachmentStops() {
    let old = UUID(), other = UUID(), new = UUID()
    #expect(RemoteAttachPolicy.decide(attached: [old, other], contentID: new, keep: false)
      == .attach(detaching: [old, other]))
  }
  @Test func withKeepTheOthersStay() {
    let old = UUID(), new = UUID()
    #expect(RemoteAttachPolicy.decide(attached: [old], contentID: new, keep: true) == .attach(detaching: []))
  }
  @Test func reAttachRestartsOnlyThatStream() {
    let same = UUID(), other = UUID()
    #expect(RemoteAttachPolicy.decide(attached: [same, other], contentID: same, keep: true)
      == .attach(detaching: [same]))
    #expect(RemoteAttachPolicy.decide(attached: [same, other], contentID: same, keep: false)
      == .attach(detaching: [same, other]))
  }
  @Test func theSeventeenthKeptAttachmentIsRefused() {
    let attached = Set((0..<16).map { _ in UUID() })
    #expect(RemoteAttachPolicy.decide(attached: attached, contentID: UUID(), keep: true) == .limitReached)
    // A re-attach at the limit is still allowed.
    #expect(RemoteAttachPolicy.decide(attached: attached, contentID: attached.first!, keep: true)
      == .attach(detaching: [attached.first!]))
  }
}
```

Add one router wiring test in the same file, with the `makeRouter` and `lanOpened` pattern of
`RemoteAccessWorktreeNewTests`: `{"t":"attach","id":2,"contentId":"<random uuid>","keep":true}` for
a content no worktree lists answers `{"t":"error","id":2,"message":"no such terminal"}` and leaves
the connection known (a following `list` is answered).

- [ ] **Step 2: Run `supacodeTests/RemoteAccessAttachTests`; expect compile failure.**

- [ ] **Step 3: Implement `RemoteAttachPolicy.decide`**, then use it in `attach`: `.limitReached`
  replies `RemoteErrorMessage(id:message:code:contentId:)` with code `attach_limit`, message
  `too many attached terminals` and the request's `contentId`, and changes nothing;
  `.attach(detaching:)` calls `detach(connID:contentID:)` for each, then starts the stream as
  today. `detachRequested` with a `contentId` stops that content only (РФ1); without one it stops
  all.

- [ ] **Step 4: Run `RemoteAccessAttachTests` and the gate suites of Task 3; expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add supacode/Features/RemoteAccess/RemoteAttachPolicy.swift supacode/Features/RemoteAccess/RemoteHostRouter.swift supacodeTests/RemoteAccessAttachTests.swift
git commit -m "feat(remote): attach keep with a limit of 16 and detach of one content (ПТ1)"
```

### Task 5: The layout in `list` (ПТ2)

**Files:**
- Create: `supacode/Features/RemoteAccess/RemoteLayoutBuilder.swift`
- Modify: `supacode/Features/RemoteAccess/RemoteProtocol.swift` (`RemoteWorktree.layout`)
- Modify: `supacode/Features/RemoteAccess/RemoteSnapshotBuilder.swift` (`WorktreeInput.layout`)
- Modify: `supacode/Features/RemoteAccess/RemoteSnapshotSource.swift` (`repositories()`)
- Test: `supacodeTests/RemoteAccessLayoutTests.swift` (new)

**Interfaces:**
- Produces:

```swift
nonisolated struct RemoteLayout: Encodable, Equatable, Sendable {
  let mode: String            // TerminalLayoutMode.rawValue
  let activeGroupId: String   // "main" in tabsPerSplit
  let groups: [RemoteLayoutGroup]
  let panes: [RemoteLayoutPane]
}
nonisolated struct RemoteLayoutGroup: Encodable, Equatable, Sendable {
  let id: String
  var focusedPaneId: String?  // omitted when nil
  var zoomedPaneId: String?   // omitted when nil
  let tree: RemoteLayoutNode
}
nonisolated indirect enum RemoteLayoutNode: Encodable, Equatable, Sendable {
  case pane(String)           // {"pane":"<id>"}
  case split(direction: String, ratio: Double, left: RemoteLayoutNode, right: RemoteLayoutNode)
                              // {"split":{"direction":…,"ratio":…,"left":…,"right":…}}
}
nonisolated struct RemoteLayoutPane: Encodable, Equatable, Sendable {
  let id: String
  let tabIds: [String]
  var selectedTabId: String?  // omitted when nil
}
nonisolated enum RemoteLayoutBuilder {
  static let mainGroupID = "main"
  /// nil for a layout with no terminal tab.
  static func build(_ layout: PaneLayout, mode: TerminalLayoutMode) -> RemoteLayout?
}
```

Ids are `rawValue.uuidString` of `PaneID`, `TabID` and `PaneGroupID`. `tabIds` holds terminal tabs
only (the same filter as `RemoteSnapshotSource.tabs(in:runtime:)`). `direction` is `"horizontal"` or
`"vertical"`; `ratio` is `SplitTree.Split.ratio`.

- [ ] **Step 1: Write the failing tests** (build fixtures as `RemoteAccessSnapshotSourceTests`
  does: `Pane`, `SplitTree(view:)`, `inserting(view:at:direction:)`).

```swift
@MainActor @Suite struct RemoteAccessLayoutTests {
  @Test func aLayoutWithNoTabsHasNoLayout() {
    #expect(RemoteLayoutBuilder.build(PaneLayout(), mode: .tabsPerSplit) == nil)
  }

  @Test func tabsPerSplitHasOneMainGroupWithItsTree() throws {
    // Two panes side by side, the second focused; fixture builds `layout`, `left`, `right`.
    let remote = try #require(RemoteLayoutBuilder.build(layout, mode: .tabsPerSplit))
    #expect(remote.mode == "tabsPerSplit")
    #expect(remote.activeGroupId == "main")
    #expect(remote.groups.map(\.id) == ["main"])
    #expect(remote.groups[0].focusedPaneId == right.id.rawValue.uuidString)
    #expect(remote.groups[0].zoomedPaneId == nil)
    #expect(remote.groups[0].tree == .split(
      direction: "horizontal", ratio: 0.5,
      left: .pane(left.id.rawValue.uuidString), right: .pane(right.id.rawValue.uuidString)))
    #expect(remote.panes.map(\.id) == [left, right].map { $0.id.rawValue.uuidString })
    #expect(remote.panes[0].tabIds == left.tabs.map { $0.id.rawValue.uuidString })
    #expect(remote.panes[0].selectedTabId == left.selectedTabID?.rawValue.uuidString)
  }

  @Test func aZoomedTreeNamesItsPane() throws {
    // Same fixture with the tree zoomed on `left`.
    let remote = try #require(RemoteLayoutBuilder.build(zoomedLayout, mode: .tabsPerSplit))
    #expect(remote.groups[0].zoomedPaneId == left.id.rawValue.uuidString)
  }

  @Test func splitPerTabListsEveryGroupInStripOrderAndEveryPane() throws {
    // РФ3: active group G1 (one pane), parked group G2 (two panes, zoomed on its second pane).
    let remote = try #require(RemoteLayoutBuilder.build(grouped, mode: .splitPerTab))
    #expect(remote.mode == "splitPerTab")
    #expect(remote.activeGroupId == g1.rawValue.uuidString)
    #expect(remote.groups.map(\.id) == [g1, g2].map { $0.rawValue.uuidString })
    #expect(remote.groups[1].zoomedPaneId == parkedSecond.id.rawValue.uuidString)
    #expect(remote.panes.count == 3)
  }

  @Test func theNodeEncodesAsTheProtocolSays() throws {
    let node = RemoteLayoutNode.split(direction: "vertical", ratio: 0.25, left: .pane("A"), right: .pane("B"))
    let json = try #require(try JSONSerialization.jsonObject(with: RemoteJSON.encode(node)) as? [String: Any])
    let split = try #require(json["split"] as? [String: Any])
    #expect(split["direction"] as? String == "vertical")
    #expect(split["ratio"] as? Double == 0.25)
    #expect((split["left"] as? [String: Any])?["pane"] as? String == "A")
  }
}
```

For the split-per-tab fixture build a tabs-per-split layout with three single-tab panes and call
`PaneLayout.convertedToSplitPerTab(…)` (`PaneLayout.swift`), as `SplitPerTabLayoutTests` does; then
zoom the parked group's tree.

- [ ] **Step 2: Run `supacodeTests/RemoteAccessLayoutTests`; expect compile failure.**

- [ ] **Step 3: Implement the types and `RemoteLayoutBuilder.build`.** Groups: in `.tabsPerSplit`
  one group `main` from `layout.tree` and `layout.focusedPaneID`; in `.splitPerTab` walk
  `layout.groupOrder`, taking the active group from `layout.tree` / `focusedPaneID` and the others
  from `layout.parkedGroups`. A group whose tree has no root is left out. `zoomedPaneId` is set only
  when the tree's `zoomed` node is a single leaf. `panes` comes from the flat `layout.panes`.

- [ ] **Step 4: Wire it.** `RemoteWorktree` and `WorktreeInput` gain `var layout: RemoteLayout?`
  (omitted when nil); `RemoteSnapshotSource.repositories()` fills it from
  `terminalManager.layoutState(for:)` (`RemoteLayoutBuilder.build(state.layout, mode: state.mode)`).

- [ ] **Step 5: Run `RemoteAccessLayoutTests`, `RemoteAccessSnapshotBuilderTests`,
  `RemoteAccessSnapshotSourceTests`; expect PASS.**

- [ ] **Step 6: Commit**

```bash
git add supacode/Features/RemoteAccess/RemoteLayoutBuilder.swift supacode/Features/RemoteAccess/RemoteProtocol.swift supacode/Features/RemoteAccess/RemoteSnapshotBuilder.swift supacode/Features/RemoteAccess/RemoteSnapshotSource.swift supacodeTests/RemoteAccessLayoutTests.swift
git commit -m "feat(remote): list carries each worktree's split layout (ПТ2)"
```

### Task 6: Pushed `list` — `watch` (ПТ3)

**Files:**
- Create: `supacode/Features/RemoteAccess/RemoteWatch.swift`
- Modify: `supacode/Features/RemoteAccess/RemoteProtocol.swift` (`RemoteWatchMessage`)
- Modify: `supacode/Features/RemoteAccess/RemoteHostRouter.swift`
- Test: `supacodeTests/RemoteAccessWatchTests.swift` (new)

**Interfaces:**
- Consumes: `RemoteInboundMessage.on`, `RemoteSnapshotSource.listMessage(id:)`.
- Produces:

```swift
nonisolated struct RemoteWatchMessage: Encodable, Equatable, Sendable {
  var t = "watch"
  let id: Int?
  let on: Bool
}
nonisolated enum RemoteWatch {
  static let interval: Duration = .milliseconds(250)
  static let titleInterval: Duration = .seconds(2)
  enum Change: Equatable { case none, titlesOnly, structural }
  /// `old` nil (nothing sent on this connection yet) is `.structural`.
  static func change(from old: RemoteListMessage?, to new: RemoteListMessage) -> Change
  /// Whether a tick sends: structural always; titles only after `titleInterval` since the last send.
  static func sends(_ change: Change, sinceLastSend: Duration) -> Bool
}
```

The router keeps, per watching connection, the last `list` it sent and when. One task runs while
at least one connection watches: every `RemoteWatch.interval` on the router's `clock` it builds
`source.listMessage(id: nil)` once and sends it to each watcher for which `sends` is true. A `list`
reply to a watching connection also records itself as the last sent. The task ends when the last
watcher leaves (`on:false`, `conn.close`, `lanClosed`, `dropAllClients`, `stop`).

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteAccessWatchTests {
  // `list(titles:)` builds a one-repo, one-worktree RemoteListMessage with tabs of these titles.
  @Test func nothingSentYetIsStructural() {
    #expect(RemoteWatch.change(from: nil, to: Self.list(titles: ["zsh"])) == .structural)
  }
  @Test func anEqualSnapshotIsNoChange() {
    #expect(RemoteWatch.change(from: Self.list(titles: ["zsh"]), to: Self.list(titles: ["zsh"])) == .none)
  }
  @Test func onlyATabTitleDiffers() {
    #expect(RemoteWatch.change(from: Self.list(titles: ["zsh"]), to: Self.list(titles: ["vim"])) == .titlesOnly)
  }
  @Test func aNewTabIsStructural() {
    #expect(RemoteWatch.change(from: Self.list(titles: ["zsh"]), to: Self.list(titles: ["zsh", "zsh"])) == .structural)
  }
  @Test func anAgentActivityChangeIsStructural() { /* same titles, agents differ → .structural */ }

  @Test func titleOnlyChangesWaitTwoSeconds() {   // РФ4
    #expect(!RemoteWatch.sends(.titlesOnly, sinceLastSend: .milliseconds(1999)))
    #expect(RemoteWatch.sends(.titlesOnly, sinceLastSend: .seconds(2)))
    #expect(RemoteWatch.sends(.structural, sinceLastSend: .zero))
    #expect(!RemoteWatch.sends(.none, sinceLastSend: .seconds(60)))
  }

  @Test func aWatchingConnectionGetsOneListAndThenNothingWhileNothingChanges() async throws {
    let clock = TestClock()
    let (router, _) = Self.makeRouter(clock: clock)      // as in RemoteAccessWorktreeNewTests
    defer { router.stop() }
    let frames = LockIsolated<[String]>([])
    router.lanOpened("c1") { frame in frames.withValue { $0.append(frame) } }
    router.receiveDirect(connID: "c1", json: Data(#"{"t":"watch","id":5,"on":true}"#.utf8))
    #expect(try Self.json(frames.value[0])["t"] as? String == "watch")
    await Task.megaYield()
    await clock.advance(by: RemoteWatch.interval)
    #expect(frames.value.count == 2)
    let pushed = try Self.json(frames.value[1])
    #expect(pushed["t"] as? String == "list")
    #expect(pushed["id"] is NSNull)
    await clock.advance(by: .seconds(5))
    #expect(frames.value.count == 2)
  }

  @Test func watchOffStopsThePushes() async throws { /* on, off, advance 1 s → only the two watch replies */ }
  @Test func aClosedConnectionStopsItsWatch() async throws { /* on, lanClosed, advance → no frame after close */ }
}
```

- [ ] **Step 2: Run `supacodeTests/RemoteAccessWatchTests`; expect compile failure.**

- [ ] **Step 3: Implement `RemoteWatch`.** `change` compares the two messages with every
  `tabs[].title` blanked: equal with titles blanked and unequal as given is `.titlesOnly`.

- [ ] **Step 4: Wire the router**: `case "watch"` in `receiveDirect` (a missing `on` means `true`),
  the reply, the per-connection record, the tick task described above, and its end.

- [ ] **Step 5: Run `RemoteAccessWatchTests` and the gate suites; expect PASS.**

- [ ] **Step 6: Commit**

```bash
git add supacode/Features/RemoteAccess/RemoteWatch.swift supacode/Features/RemoteAccess/RemoteProtocol.swift supacode/Features/RemoteAccess/RemoteHostRouter.swift supacodeTests/RemoteAccessWatchTests.swift
git commit -m "feat(remote): watch pushes list on change, titles at most every 2 s (ПТ3)"
```

### Task 7: Layout actions — `tab.close`, `pane.split`, `pane.close`, `tab.new.paneId` (ПТ4)

**Files:**
- Create: `supacode/Features/RemoteAccess/RemoteLayoutActions.swift`
- Modify: `supacode/Features/RemoteAccess/RemoteProtocol.swift` (reply types)
- Modify: `supacode/Features/RemoteAccess/RemoteSnapshotSource.swift`
- Modify: `supacode/Features/RemoteAccess/RemoteHostRouter.swift`
- Test: `supacodeTests/RemoteAccessLayoutActionTests.swift` (new), `supacodeTests/RemoteAccessTabNewTests.swift`

**Interfaces:**
- Consumes: `RemoteInboundMessage.tabId` / `.paneId` / `.direction`;
  `WorktreeTerminalManager.sendLayout(_:_:)`, `.layoutState(for:)`, `.handleCommand(_:)`.
- Produces:

```swift
nonisolated enum RemoteLayoutActionRejection: Error, Equatable {
  case missingTab, unknownTab, missingPane, unknownPane, badDirection, stillThere
  var code: String      // tab_invalid | pane_invalid | tab_failed | pane_failed
  var message: String
}
nonisolated enum RemoteLayoutActions {
  /// "horizontal" / "vertical" → SplitDirection; anything else nil.
  static func direction(_ raw: RemoteLenientString?) -> SplitDirection?
  /// The layout that holds this tab / pane, searched over every worktree's layout.
  static func locate(tab: UUID, in layouts: [(worktreeID: String, layout: PaneLayout)]) -> String?
  static func locate(pane: UUID, in layouts: [(worktreeID: String, layout: PaneLayout)]) -> String?
}
nonisolated struct RemoteTabCloseMessage: Encodable, Equatable, Sendable { var t = "tab.close"; let id: Int?; let tabId: String; let worktreeId: String }
nonisolated struct RemotePaneCloseMessage: Encodable, Equatable, Sendable { var t = "pane.close"; let id: Int?; let paneId: String; let worktreeId: String }
nonisolated struct RemotePaneSplitMessage: Encodable, Equatable, Sendable {
  var t = "pane.split"; let id: Int?; let worktreeId: String; let paneId: String; let tabId: String; let contentId: String
}
// RemoteSnapshotSource
func requestCloseTab(tabID raw: String?) -> Result<String, RemoteLayoutActionRejection>            // worktree id
func requestClosePane(paneID raw: String?) -> Result<String, RemoteLayoutActionRejection>          // worktree id
func requestSplitPane(paneID raw: String?, direction: RemoteLenientString?)
  -> Result<(worktreeID: String, newID: UUID), RemoteLayoutActionRejection>
func paneID(ofTab tabID: UUID, in worktreeID: String) -> UUID?
func requestNewTab(worktreeID raw: String, paneID: String?, startGrid: TerminalStartGrid) -> Result<UUID, RemoteTabNewRejection>
```

The three reply structs encode `id` as an explicit `null` when nil, as `RemoteListMessage` does.
Rejection texts: `tab.close needs a tabId`, `no such tab`, `pane.close needs a paneId` /
`pane.split needs a paneId`, `no such pane`, `direction must be horizontal or vertical`,
`the tab is still open on the Mac` / `the pane is still open on the Mac`,
`the new pane did not start on the Mac`.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteAccessLayoutActionTests {
  @Test func directionAcceptsOnlyTheTwoAxes() {
    #expect(RemoteLayoutActions.direction(RemoteLenientString("horizontal")) == .horizontal)
    #expect(RemoteLayoutActions.direction(RemoteLenientString("vertical")) == .vertical)
    for bad in ["right", "h", "", "Horizontal"] {
      #expect(RemoteLayoutActions.direction(RemoteLenientString(bad)) == nil)
    }
    #expect(RemoteLayoutActions.direction(RemoteLenientString(nil)) == nil)
    #expect(RemoteLayoutActions.direction(nil) == nil)
  }

  @Test func aTabAndAPaneAreFoundInTheLayoutThatHoldsThem() {
    // Two worktrees "/a" and "/b"; "/b" has a parked split-per-tab group holding `parkedTab`.
    #expect(RemoteLayoutActions.locate(tab: parkedTab.id.rawValue, in: layouts) == "/b")
    #expect(RemoteLayoutActions.locate(pane: paneOfA.id.rawValue, in: layouts) == "/a")
    #expect(RemoteLayoutActions.locate(tab: UUID(), in: layouts) == nil)
  }

  @Test func rejectionsCarryTheirCodes() {
    #expect(RemoteLayoutActionRejection.unknownTab.code == "tab_invalid")
    #expect(RemoteLayoutActionRejection.missingPane.code == "pane_invalid")
    #expect(RemoteLayoutActionRejection.badDirection.code == "pane_invalid")
  }

  // Router wiring, with the makeRouter + lanOpened pattern:
  @Test func tabCloseOfAnUnknownTabAnswersTabInvalid() async throws {
    // {"t":"tab.close","id":6,"tabId":"<random uuid>"} → error, id 6, code tab_invalid, message "no such tab"
  }
  @Test func tabCloseWithoutATabIDAnswersTabInvalid() async throws { /* message "tab.close needs a tabId" */ }
  @Test func paneSplitWithABadDirectionAnswersPaneInvalid() async throws {
    // {"t":"pane.split","id":7,"paneId":"<random uuid>","direction":"right"} → code pane_invalid
  }
  @Test func paneCloseOfAnUnknownPaneAnswersPaneInvalid() async throws { /* id 8, code pane_invalid */ }
  @Test func theRepliesEncodeANullID() throws {
    let json = try Self.json(RemoteJSON.encode(RemoteTabCloseMessage(id: nil, tabId: "T", worktreeId: "/a")))
    #expect(json["id"] is NSNull)
    #expect(json["t"] as? String == "tab.close")
  }
}
```

In `RemoteAccessTabNewTests` add: a `tab.new` whose `paneId` is not a UUID, or names no pane of that
worktree, opens the tab exactly as one without `paneId` (same request recorded).

- [ ] **Step 2: Run `supacodeTests/RemoteAccessLayoutActionTests`; expect compile failure.**

- [ ] **Step 3: Implement the pure types, then the source methods.**
  - `requestCloseTab`: locate the worktree; `terminalManager.sendLayout(id, .closeTab(id: TabID(rawValue:)))`;
    then read the layout again: tab still present → `.failure(.stillThere)`.
  - `requestClosePane`: same with `.closePane(id:)`.
  - `requestSplitPane`: validate the direction first (`.badDirection`), locate the pane, find its
    `Worktree` value in `store.repositories`, mint `newID = UUID()`, and send
    `terminalManager.handleCommand(.splitPane(worktree, paneToken: paneUUID, direction: direction, input: nil, id: newID, focusing: false))`.
    That command uses `id` for both the new tab id and the new content id.
  - `requestNewTab(…paneID:…)`: pass `anchor: UUID(uuidString: paneID)` to `.createTab` only when it
    names a pane of that worktree's layout and the layout's mode is `.tabsPerSplit`; otherwise
    `anchor: nil` and one log line.

- [ ] **Step 4: Wire the router.** `tab.close` and `pane.close` answer at once from the source's
  result. `pane.split` waits like `newTab`: `Self.poll(every: Self.tabNewPollInterval, within: Self.tabNewTimeout, clock:)`
  until `source.paneID(ofTab: newID, in: worktreeID)` is non-nil, registers the wait in
  `requestWaits`, then replies `RemotePaneSplitMessage` with `tabId == contentId == newID.uuidString`;
  on timeout it replies `pane_failed`. Errors use `replyError(_:id:_:code:)`.

- [ ] **Step 5: Run `RemoteAccessLayoutActionTests`, `RemoteAccessTabNewTests` and the gate
  suites; expect PASS.**

- [ ] **Step 6: Commit**

```bash
git add supacode/Features/RemoteAccess/RemoteLayoutActions.swift supacode/Features/RemoteAccess/RemoteProtocol.swift supacode/Features/RemoteAccess/RemoteSnapshotSource.swift supacode/Features/RemoteAccess/RemoteHostRouter.swift supacodeTests/RemoteAccessLayoutActionTests.swift supacodeTests/RemoteAccessTabNewTests.swift
git commit -m "feat(remote): tab.close, pane.split, pane.close and tab.new paneId (ПТ4)"
```

### Task 8: A pinned grid on the surface and the terminal content (ХС7)

**Files:**
- Modify: `supacode/Infrastructure/Ghostty/GhosttySurfaceView.swift` (`RequestedGridHold`, `updateSurfaceSize`, `viewDidMoveToWindow`, `updateCellSize`)
- Modify: `supacode/Features/Terminal/Content/TabContent.swift` (`TerminalContent`)
- Modify: `supacode/Features/RemoteAccess/RemoteSnapshotSource.swift`
- Test: `supacodeTests/TerminalRenderingPolicyTests.swift` (the existing `RequestedGridHold` tests are there)

**Interfaces:**
- Produces:

```swift
// GhosttySurfaceView.RequestedGridHold
private(set) var isPinned: Bool
/// Like `hold`, and the hold then survives every layout pass until `release()`.
mutating func pin(replacing paneBackingSize: CGSize)

// GhosttySurfaceView
/// Holds exactly this grid until `unpinGrid()`, whatever the pane measures and
/// whichever window the view is in; re-applied when the cell metrics change.
func pinGrid(columns: Int, rows: Int) -> RequestedGridOutcome
func unpinGrid()

// TerminalContent
/// The pinned grid, kept across hibernate and wake; nil when not pinned.
private(set) var pinnedGrid: (columns: Int, rows: Int)?
/// nil while there is no live surface: the pin is recorded and applied when one exists.
func pinGrid(columns: Int, rows: Int) -> GhosttySurfaceView.RequestedGridOutcome?
func unpinGrid()

// RemoteSnapshotSource
func pinGrid(contentID: UUID, columns: Int, rows: Int) -> RemoteResizeAttempt   // mapped as resizeGrid does
func unpinGrid(contentID: UUID)
```

`keeps(layoutBackingSize:)` while pinned always returns true and records the measured size as the
pane's, so `release()` gives back the pane's newest size.

- [ ] **Step 1: Write the failing tests** (next to the existing `RequestedGridHold` tests)

```swift
@Test func aPinnedHoldSurvivesADifferentPaneSize() {   // РФ5
  var hold = GhosttySurfaceView.RequestedGridHold()
  hold.pin(replacing: CGSize(width: 800, height: 600))
  let first = hold.keeps(layoutBackingSize: CGSize(width: 1000, height: 700))
  let second = hold.keeps(layoutBackingSize: CGSize(width: 640, height: 480))
  #expect(first)
  #expect(second)
  #expect(hold.isPinned)
}

@Test func releasingAPinnedHoldReturnsTheNewestPaneSize() {
  var hold = GhosttySurfaceView.RequestedGridHold()
  hold.pin(replacing: CGSize(width: 800, height: 600))
  _ = hold.keeps(layoutBackingSize: CGSize(width: 1000, height: 700))
  let released = hold.release()
  #expect(released == CGSize(width: 1000, height: 700))
  #expect(!hold.isPinned)
}

@Test func anOrdinaryHoldStillEndsOnADifferentPaneSize() {
  var hold = GhosttySurfaceView.RequestedGridHold()
  hold.hold(replacing: CGSize(width: 800, height: 600))
  let kept = hold.keeps(layoutBackingSize: CGSize(width: 1000, height: 700))
  #expect(!kept)
}

@Test func pinningOverAnOrdinaryHoldKeepsThePaneSizeItReplaced() {
  var hold = GhosttySurfaceView.RequestedGridHold()
  hold.hold(replacing: CGSize(width: 800, height: 600))
  hold.pin(replacing: CGSize(width: 111, height: 111))
  #expect(hold.release() == CGSize(width: 800, height: 600))
}
```

- [ ] **Step 2: Run `supacodeTests/TerminalRenderingPolicyTests`; expect compile failure.**

- [ ] **Step 3: Implement `pin` and `isPinned`**, then the surface: `pinGrid` computes the backing
  size as `applyRequestedGrid` does (`GridCap.backingSize(…exact: true)`), calls
  `requestedGridHold.pin(replacing: lastAppliedBackingSize)` and pushes the size; it also handles a
  never-shown surface through `capUnmountedGrid(…exact: true)`. `viewDidMoveToWindow` skips
  `releaseRequestedGrid()` while pinned. `updateCellSize` re-applies the pinned grid (a font or
  scale change must keep columns × rows). `unpinGrid` calls `releaseRequestedGrid()`.

- [ ] **Step 4: Implement `TerminalContent.pinGrid` / `unpinGrid`**: store `pinnedGrid`, forward to
  `surfaceView`; where the content installs a new surface (start, wake, restore) call
  `surfaceView.pinGrid` when `pinnedGrid` is set. Add the two `RemoteSnapshotSource` methods.

- [ ] **Step 5: Run `supacodeTests/TerminalRenderingPolicyTests` and
  `supacodeTerminalTests/GhosttySurfaceViewTests` (it covers `applyRequestedGrid`); expect PASS.**

- [ ] **Step 6: Commit**

```bash
git add supacode/Infrastructure/Ghostty/GhosttySurfaceView.swift supacode/Features/Terminal/Content/TabContent.swift supacode/Features/RemoteAccess/RemoteSnapshotSource.swift supacodeTests/TerminalRenderingPolicyTests.swift
git commit -m "feat(terminal): a pinned grid that survives layout, window and wake (ХС7)"
```

### Task 9: The held size — `resize` with `hold` (ПТ6)

**Files:**
- Create: `supacode/Features/RemoteAccess/RemoteGridHolds.swift`
- Modify: `supacode/Features/RemoteAccess/RemoteProtocol.swift` (`RemoteResizeRequest.hold`)
- Modify: `supacode/Features/RemoteAccess/RemoteHostRouter.swift`
- Test: `supacodeTests/RemoteAccessGridHoldTests.swift` (new), `supacodeTests/RemoteAccessResizeTests.swift`

**Interfaces:**
- Consumes: `RemoteInboundMessage.hold`; `RemoteSnapshotSource.pinGrid` / `unpinGrid` (Task 8).
- Produces:

```swift
// RemoteResizeRequest
var hold = false            // set by resolve from message.hold == true

nonisolated struct RemoteGridHolds {
  static let grace: Duration = .seconds(30)
  struct Hold: Equatable { var owner: String?; let columns: Int; let rows: Int }   // owner nil: in its 30 s
  private(set) var byContent: [UUID: Hold]

  /// A `resize` with `hold:true`: this connection owns the hold now.
  mutating func take(contentID: UUID, connID: String, columns: Int, rows: Int)
  /// A `resize` without `hold`, a failed held resize, or the terminal ending. True when a hold ended.
  mutating func drop(contentID: UUID) -> Bool
  /// The owner sent `detach` (or attached elsewhere without `keep`). True when the hold ended.
  mutating func ownerDetached(contentID: UUID, connID: String) -> Bool
  /// The owner's connection closed or its stream failed: the hold stays, without an owner.
  /// Returns the contents whose 30 s start now.
  mutating func ownerLost(connID: String, contentID: UUID?) -> [UUID]
  /// The 30 s passed. True when the hold is still without an owner and so ends.
  mutating func graceExpired(contentID: UUID) -> Bool
}

// RemoteHostRouter
nonisolated static func redrawInput(
  for outcome: Result<RemoteResizeConfirmation, RemoteResizeResult.Failure>, isReadOnly: Bool, hold: Bool) -> [UInt8]
```

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct RemoteAccessGridHoldTests {
  static let tab = UUID()

  @Test func theLastHoldingRequestOwnsTheSize() {
    var holds = RemoteGridHolds()
    holds.take(contentID: Self.tab, connID: "c1", columns: 100, rows: 30)
    holds.take(contentID: Self.tab, connID: "c2", columns: 120, rows: 40)
    #expect(holds.byContent[Self.tab] == .init(owner: "c2", columns: 120, rows: 40))
  }

  @Test func onlyTheOwnersDetachEndsTheHold() {
    var holds = RemoteGridHolds()
    holds.take(contentID: Self.tab, connID: "c1", columns: 100, rows: 30)
    let byOther = holds.ownerDetached(contentID: Self.tab, connID: "c2")
    #expect(!byOther)
    let byOwner = holds.ownerDetached(contentID: Self.tab, connID: "c1")
    #expect(byOwner)
    #expect(holds.byContent.isEmpty)
  }

  @Test func aLostConnectionKeepsTheHoldForItsGrace() {   // РФ5
    var holds = RemoteGridHolds()
    holds.take(contentID: Self.tab, connID: "c1", columns: 100, rows: 30)
    let orphaned = holds.ownerLost(connID: "c1", contentID: nil)
    #expect(orphaned == [Self.tab])
    #expect(holds.byContent[Self.tab] == .init(owner: nil, columns: 100, rows: 30))
    // A new connection takes it over inside the 30 s: the timer then ends nothing.
    holds.take(contentID: Self.tab, connID: "c2", columns: 100, rows: 30)
    let expired = holds.graceExpired(contentID: Self.tab)
    #expect(!expired)
    #expect(holds.byContent[Self.tab]?.owner == "c2")
  }

  @Test func theGraceEndsAnOrphanedHold() {
    var holds = RemoteGridHolds()
    holds.take(contentID: Self.tab, connID: "c1", columns: 100, rows: 30)
    _ = holds.ownerLost(connID: "c1", contentID: nil)
    let expired = holds.graceExpired(contentID: Self.tab)
    #expect(expired)
    #expect(holds.byContent.isEmpty)
  }

  @Test func losingOneStreamOrphansOnlyThatContent() {
    var holds = RemoteGridHolds()
    let other = UUID()
    holds.take(contentID: Self.tab, connID: "c1", columns: 100, rows: 30)
    holds.take(contentID: other, connID: "c1", columns: 80, rows: 24)
    #expect(holds.ownerLost(connID: "c1", contentID: other) == [other])
    #expect(holds.byContent[Self.tab]?.owner == "c1")
  }

  @Test func aLostConnectionThatOwnsNothingChangesNothing() {
    var holds = RemoteGridHolds()
    holds.take(contentID: Self.tab, connID: "c1", columns: 100, rows: 30)
    #expect(holds.ownerLost(connID: "c2", contentID: nil).isEmpty)
  }

  @Test func aPlainResizeEndsTheHold() {
    var holds = RemoteGridHolds()
    holds.take(contentID: Self.tab, connID: "c1", columns: 100, rows: 30)
    let ended = holds.drop(contentID: Self.tab)
    #expect(ended)
  }
}
```

```swift
// RemoteAccessResizeTests
@Test func aHeldResizeSendsNoRedrawKey() {
  #expect(RemoteHostRouter.redrawInput(for: .success(.matched), isReadOnly: false, hold: true).isEmpty)
  #expect(RemoteHostRouter.redrawInput(for: .success(.matched), isReadOnly: false, hold: false) == [0x0C])
}

// RemoteAccessProtocolTests
@Test func resizeCarriesHold() {
  let id = UUID()
  let message = RemoteInboundMessage(
    t: "resize", contentId: id.uuidString, cols: RemoteLenientInt(100), rows: RemoteLenientInt(30), hold: true)
  #expect(RemoteResizeRequest.resolve(message, attached: [id])
    == .success(RemoteResizeRequest(contentID: id, columns: 100, rows: 30, hold: true)))
}
```

- [ ] **Step 2: Run `supacodeTests/RemoteAccessGridHoldTests`; expect compile failure.**

- [ ] **Step 3: Implement `RemoteGridHolds`, `RemoteResizeRequest.hold` and the `hold:` parameter
  of `redrawInput`** (update its existing callers and tests with `hold: false`).

- [ ] **Step 4: Wire the router.** It owns `private var gridHolds = RemoteGridHolds()` and one
  grace task per orphaned content (`[UUID: Task<Void, Never>]`, sleeping `RemoteGridHolds.grace` on
  `clock`).
  - `resize` with `hold`: `gridHolds.take` at once, then the usual wait with the probes' `attempt`
    calling `source.pinGrid` instead of `source.resizeGrid`; on `resize_failed` call `drop` and
    `source.unpinGrid`. A taken hold cancels that content's grace task.
  - `resize` without `hold`: `drop` (then `source.unpinGrid`) before the usual path.
  - `detach(connID:contentID:)` from a client request or from an `attach` without `keep`:
    `ownerDetached`; when true, `source.unpinGrid` (РФ2).
  - `conn.close`, `lanClosed`, `dropAllClients`, `streamClosed`: `ownerLost`, and start the grace
    task for each returned content; when it fires and `graceExpired` is true, `source.unpinGrid`.
  - `stop()`: cancel the grace tasks and unpin every held content.
  - After an unpin the existing 2 s size poll sends `size` to every client attached to that
    content; nothing else is needed for "every attached client gets `size`".

- [ ] **Step 5: Add the router test** in `RemoteAccessGridHoldTests`, with a `TestClock`: a
  connection that never attached sends `{"t":"resize","contentId":"<uuid>","cols":100,"rows":30,"hold":true}`
  and gets no reply and no hold (it is not attached), as today's `resize` for a content it is not
  attached to.

- [ ] **Step 6: Run `RemoteAccessGridHoldTests`, `RemoteAccessResizeTests`,
  `RemoteAccessProtocolTests` and the gate suites; expect PASS.**

- [ ] **Step 7: Commit**

```bash
git add supacode/Features/RemoteAccess/RemoteGridHolds.swift supacode/Features/RemoteAccess/RemoteProtocol.swift supacode/Features/RemoteAccess/RemoteHostRouter.swift supacodeTests/RemoteAccessGridHoldTests.swift supacodeTests/RemoteAccessResizeTests.swift supacodeTests/RemoteAccessProtocolTests.swift
git commit -m "feat(remote): resize hold keeps a client's size, 30 s after a lost connection (ПТ6)"
```

### Task 10: The simulator, the full run and the live check

**Files:**
- Modify: `remote-relay/scripts/phone-sim.mjs`
- Modify: `docs/fork.md` ("Remote Access From The Android App": the new messages and files)
- Modify: `docs/plans/2026-11-17-remote-client-design.md` ("Not confirmed": the measured frame rate)

**Interfaces:**
- Consumes: every message of Tasks 2–9.
- Produces: `phone-sim.mjs` modes, each printing every frame it receives as one JSON line:
  - no mode: `hello` (prints `caps`), `list` (prints each worktree's `layout`).
  - `--watch <seconds>`: `watch` on, prints pushed `list` frames for that time.
  - `<contentA> <contentB> attach2`: two `attach` with `keep:true`, 5 s of frames, `detach` of A,
    3 s more (only B's `out`), then exit.
  - `<contentId> rate <seconds>`: attaches and prints `out` frames per second and bytes per second.
  - `<contentId> hold <cols> <rows>`: attach, `resize` with `hold:true`, prints the `size`, waits
    for Enter, then closes.
  - `<tabId> tab-close`, `<paneId> pane-split <horizontal|vertical>`, `<paneId> pane-close`.

- [ ] **Step 1: Extend `phone-sim.mjs`** with the modes above, in the file's existing style.

- [ ] **Step 2: Full test run**

```bash
mkdir -p ./tmp/claude-logs && LOG=./tmp/claude-logs/make-test-$(date +%Y%m%d-%H%M%S).log && make test > "$LOG" 2>&1; command tail -n 60 "$LOG"
```

Expected: all bundles pass and `check-isolated-deinits.sh` passes. Rerun once on a failure in a
known flaky test (`.agent-memory/test-and-lint-traps.md`).

- [ ] **Step 3: Build**

```bash
mkdir -p ./tmp/claude-logs && LOG=./tmp/claude-logs/build-app-$(date +%Y%m%d-%H%M%S).log && make build-app > "$LOG" 2>&1; command tail -n 40 "$LOG"
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Live check against an isolated second Supacode.** Start the built app as a second
  host (`CFFIXED_USER_HOME=<dir>`, `ZMX_DIR=<short dir>`, `SUPACODE_REMOTE_ACCESS=1`,
  `SUPACODE_REMOTE_HOST_ID=test-host`), open a repository with two tabs and one split in it, then
  with `node remote-relay/scripts/phone-sim.mjs --host test-host …` check and record each result:
  1. `caps` lists the seven values; `layout` shows the split with two panes.
  2. `--watch 20`: a new tab on the Mac gives one pushed `list` within about a second; an idle Mac
     gives none.
  3. `attach2`: `out` frames for both contents, then only for B.
  4. `pane-split`, then `tab-close` and `pane-close` of what it made: the Mac's layout follows and
     shows no confirmation.
  5. `hold 100 30`: `size` 100×30; resize the Mac's window: no new `size`; press Enter: within
     about 32 s a `size` with the pane's own grid arrives on a second watching simulator.
  6. The installed app stays online on the relay under its own host id the whole time.

- [ ] **Step 5: Measure the frame rate (РС1).** Run `rate 60` on a tab where an agent works and on
  an idle shell. Write both numbers into the spec's "Not confirmed" entry on relay volume, with the
  daily total they give for four busy tabs over eight hours against the 2,000,000 limit, and say
  whether joining `out` frames on the host is needed. Do not build the joining in this plan.

- [ ] **Step 6: Update `docs/fork.md`**: the new files under `supacode/Features/RemoteAccess/`, the
  pinned grid in `GhosttySurfaceView` / `TerminalContent`, and the suites that guard them.

- [ ] **Step 7: Commit**

```bash
git add remote-relay/scripts/phone-sim.mjs docs/fork.md docs/plans/2026-11-17-remote-client-design.md
git commit -m "chore(remote): phone-sim modes for the new messages, fork notes, measured out rate"
```

## After this plan

Tell the owner that `supacode-remote/tools/mock-host.mjs` can now learn the same messages (spec,
"Work in `supacode-remote`"). The client plan starts from a host that passes Task 10.
