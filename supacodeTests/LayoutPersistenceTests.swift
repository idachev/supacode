import AppKit
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct LayoutPersistenceTests {
  private final class StubContent: TabContent {
    let id: ContentID
    let kind: ContentKind = .terminal
    var snapshotState: TerminalContentState

    init(id: ContentID, snapshotState: TerminalContentState) {
      self.id = id
      self.snapshotState = snapshotState
    }

    var renderer: NSView? { nil }
    func startSession(at geometry: ContentGeometry) {}
    func hibernate() {}
    func snapshot() -> ContentSnapshot {
      ContentSnapshot(id: id, state: .terminal(snapshotState))
    }
  }

  private func layout(paneID: PaneID, tabID: TabID, contentID: ContentID) -> PaneLayout {
    PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: tabID,
              title: "One",
              content: ContentSnapshot(
                id: contentID,
                state: .terminal(TerminalContentState(workingDirectory: "/stored"))
              )
            )
          ],
          selectedTabID: tabID
        )
      ],
      focusedPaneID: paneID
    )
  }

  @Test func overlaysTheChromesReportedTitle() {
    let paneID = PaneID()
    let tabID = TabID()
    let contentID = ContentID()
    let runtime = ContentRuntime()
    let live = ChromeTabContent(id: contentID)
    _ = runtime.provision(live, at: .fallback)
    live.terminalChrome.reportedTitle = "claude"

    // Reported titles never reach the reducer, so the snapshot pull is their
    // only path to disk.
    let record = LayoutPersistence.record(
      for: layout(paneID: paneID, tabID: tabID, contentID: contentID),
      runtime: runtime
    )
    #expect(record.layout.panes[id: paneID]?.tabs[id: tabID]?.title == "claude")
  }

  @Test func keepsTheStoredTitleForContentThatNeverReported() {
    let paneID = PaneID()
    let tabID = TabID()
    let contentID = ContentID()
    let runtime = ContentRuntime()
    _ = runtime.provision(ChromeTabContent(id: contentID), at: .fallback)

    let record = LayoutPersistence.record(
      for: layout(paneID: paneID, tabID: tabID, contentID: contentID),
      runtime: runtime
    )
    #expect(record.layout.panes[id: paneID]?.tabs[id: tabID]?.title == "One")
  }

  @Test func overlaysLiveSnapshotsOverStoredOnes() throws {
    let paneID = PaneID()
    let tabID = TabID()
    let contentID = ContentID()
    let runtime = ContentRuntime()
    let grid = try #require(
      FrozenGrid.from(backingSize: CGSize(width: 1024, height: 768), columns: 80, rows: 24, scale: 2, fontSize: 13)
    )
    let live = StubContent(
      id: contentID,
      snapshotState: TerminalContentState(workingDirectory: "/live", frozenGrid: grid)
    )
    _ = runtime.provision(live, at: .fallback)

    let record = LayoutPersistence.record(
      for: layout(paneID: paneID, tabID: tabID, contentID: contentID),
      runtime: runtime
    )
    let saved = record.layout.panes[id: paneID]?.tabs[id: tabID]?.content.state
    guard case .terminal(let state) = saved else {
      Issue.record("Expected a terminal payload.")
      return
    }
    // The last applied grid wins over the stored one, so a quit-time save can
    // never persist a stale grid.
    #expect(state.workingDirectory == "/live")
    #expect(state.frozenGrid == grid)
  }

  @Test func stripsBlockingScriptTabsAndRetargetsSelectionLeft() {
    let paneID = PaneID()
    let keptTab = TabID()
    let scriptTab = TabID()
    let keptContent = ContentID()
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: keptTab,
              title: "Shell",
              content: ContentSnapshot(
                id: keptContent,
                state: .terminal(TerminalContentState(workingDirectory: "/kept"))
              )
            ),
            TabItem(
              id: scriptTab,
              title: "Setup",
              content: ContentSnapshot(
                id: ContentID(),
                state: .terminal(
                  TerminalContentState(
                    workingDirectory: nil,
                    launch: LaunchOverride(command: "./setup.sh", bypassZmx: true)
                  )
                )
              ),
              isLocked: true
            ),
          ],
          selectedTabID: scriptTab
        )
      ],
      focusedPaneID: paneID
    )
    let record = LayoutPersistence.record(for: layout, runtime: ContentRuntime())
    let pane = record.layout.panes[id: paneID]
    #expect(pane?.tabs.map(\.id) == [keptTab])
    #expect(pane?.selectedTabID == keptTab)
    #expect(record.layout.isConsistent)
  }

  @Test func stripsAPaneEmptiedByItsBlockingScriptTab() {
    let keptPaneID = PaneID()
    let scriptPaneID = PaneID()
    let keptTab = TabID()
    let scriptTab = TabID()
    var tree = SplitTree<PaneID>(view: keptPaneID)
    tree = (try? tree.inserting(view: scriptPaneID, at: keptPaneID, direction: .right)) ?? tree
    let layout = PaneLayout(
      tree: tree,
      panes: [
        Pane(
          id: keptPaneID,
          tabs: [
            TabItem(
              id: keptTab,
              title: "Shell",
              content: ContentSnapshot(
                id: ContentID(),
                state: .terminal(TerminalContentState(workingDirectory: "/kept"))
              )
            )
          ],
          selectedTabID: keptTab
        ),
        Pane(
          id: scriptPaneID,
          tabs: [
            TabItem(
              id: scriptTab,
              title: "Setup",
              content: ContentSnapshot(
                id: ContentID(),
                state: .terminal(
                  TerminalContentState(
                    workingDirectory: nil,
                    launch: LaunchOverride(command: "./setup.sh", bypassZmx: true)
                  )
                )
              )
            )
          ],
          selectedTabID: scriptTab
        ),
      ],
      focusedPaneID: scriptPaneID
    )
    let record = LayoutPersistence.record(for: layout, runtime: ContentRuntime())
    #expect(record.layout.panes.map(\.id) == [keptPaneID])
    #expect(record.layout.tree.leaves() == [keptPaneID])
    #expect(record.layout.focusedPaneID == keptPaneID)
    #expect(record.layout.isConsistent)
  }

  @Test func launchOverridesNeverReachTheWire() throws {
    // A non-blocking command tab persists, but its command must not replay on
    // restore: the encoder drops the launch payload entirely.
    let state = TerminalContentState(
      workingDirectory: "/w",
      launch: LaunchOverride(command: "echo hi", initialInput: "input")
    )
    let data = try JSONEncoder().encode(state)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains("echo hi"))
    let decoded = try JSONDecoder().decode(TerminalContentState.self, from: data)
    #expect(decoded.launch == nil)
    #expect(decoded.workingDirectory == "/w")
  }

  @Test func overlaysLiveAgentRecordsPerContent() {
    let paneID = PaneID()
    let tabID = TabID()
    let contentID = ContentID()
    let record = TerminalLayoutSnapshot.SurfaceAgentRecord(agent: "claude", pids: [123], activity: "busy")
    let result = LayoutPersistence.record(
      for: layout(paneID: paneID, tabID: tabID, contentID: contentID),
      runtime: ContentRuntime(),
      agentsBySurface: [contentID.rawValue: [record]]
    )
    guard case .terminal(let state) = result.layout.panes[id: paneID]?.tabs[id: tabID]?.content.state else {
      Issue.record("Expected a terminal payload.")
      return
    }
    #expect(state.agents == [record])
    // The stored working directory survives the overlay.
    #expect(state.workingDirectory == "/stored")
  }

  @Test func clearsAgentsForLiveContentAbsentFromPresenceMap() {
    let paneID = PaneID()
    let tabID = TabID()
    let contentID = ContentID()
    let runtime = ContentRuntime()
    let record = TerminalLayoutSnapshot.SurfaceAgentRecord(agent: "claude", pids: [123], activity: "busy")
    let live = StubContent(
      id: contentID,
      snapshotState: TerminalContentState(workingDirectory: "/live", agents: [record])
    )
    _ = runtime.provision(live, at: .fallback)

    // The presence map is authoritative for live content: absence clears.
    let result = LayoutPersistence.record(
      for: layout(paneID: paneID, tabID: tabID, contentID: contentID),
      runtime: runtime,
      agentsBySurface: [:]
    )
    guard case .terminal(let state) = result.layout.panes[id: paneID]?.tabs[id: tabID]?.content.state else {
      Issue.record("Expected a terminal payload.")
      return
    }
    #expect(state.agents == nil)
  }

  @Test func keepsStoredAgentsForDormantContentAbsentFromPresenceMap() {
    let paneID = PaneID()
    let tabID = TabID()
    let contentID = ContentID()
    let record = TerminalLayoutSnapshot.SurfaceAgentRecord(agent: "claude", pids: [123], activity: "busy")
    var stored = layout(paneID: paneID, tabID: tabID, contentID: contentID)
    stored.panes[id: paneID]?.tabs[id: tabID]?.content = ContentSnapshot(
      id: contentID,
      state: .terminal(TerminalContentState(workingDirectory: "/stored", agents: [record]))
    )

    let result = LayoutPersistence.record(for: stored, runtime: ContentRuntime())
    guard case .terminal(let state) = result.layout.panes[id: paneID]?.tabs[id: tabID]?.content.state else {
      Issue.record("Expected a terminal payload.")
      return
    }
    #expect(state.agents == [record])
  }

  @Test func stripsLiveOnlyFieldsSoRecordsEqualTheirDecodedRoundTrip() {
    let paneID = PaneID()
    let tabID = TabID()
    let contentID = ContentID()
    var stored = layout(paneID: paneID, tabID: tabID, contentID: contentID)
    stored.panes[id: paneID]?.tabs[id: tabID]?.isLocked = true
    stored.panes[id: paneID]?.tabs[id: tabID]?.content = ContentSnapshot(
      id: contentID,
      state: .terminal(
        TerminalContentState(
          workingDirectory: "/stored",
          launch: LaunchOverride(initialInput: "echo hi\r")
        )
      )
    )

    let result = LayoutPersistence.record(for: stored, runtime: ContentRuntime())
    let tab = result.layout.panes[id: paneID]?.tabs[id: tabID]
    #expect(tab?.isLocked == false)
    guard case .terminal(let state) = tab?.content.state else {
      Issue.record("Expected a terminal payload.")
      return
    }
    // Wire round-trips drop the launch; the in-memory record must match, or
    // the writer's no-op gate would see a phantom change on every flush.
    #expect(state.launch == nil)
    #expect(state.workingDirectory == "/stored")
  }

  @Test func keepsStoredSnapshotWhenContentIsHibernated() {
    let paneID = PaneID()
    let tabID = TabID()
    let contentID = ContentID()
    let runtime = ContentRuntime()

    // No live content registered: the stored snapshot must survive verbatim.
    let record = LayoutPersistence.record(
      for: layout(paneID: paneID, tabID: tabID, contentID: contentID),
      runtime: runtime
    )
    let saved = record.layout.panes[id: paneID]?.tabs[id: tabID]?.content.state
    guard case .terminal(let state) = saved else {
      Issue.record("Expected a terminal payload.")
      return
    }
    #expect(state.workingDirectory == "/stored")
  }

  // MARK: - Split per tab: strip then fold.

  @Test func v2LayoutPersistsWithoutASidecar() {
    let record = LayoutPersistence.record(
      for: layout(paneID: PaneID(), tabID: TabID(), contentID: ContentID()),
      runtime: ContentRuntime()
    )
    #expect(record.splitPerTab == nil)
  }

  @Test func splitPerTabLayoutPersistsItsV2FoldPlusASidecar() throws {
    let fixture = SplitPerTabPersistenceFixture()
    let live = fixture.layout()
    #expect(live.isConsistent(for: .splitPerTab))

    let record = LayoutPersistence.record(for: live, runtime: ContentRuntime())

    // The base is the consistent v2 projection and holds every content, parked
    // groups included, so the orphan reaper sees all of them.
    #expect(record.layout.activeGroupID == nil)
    #expect(record.layout.isConsistent(for: .tabsPerSplit))
    #expect(Set(record.layout.allContentIDs) == Set(fixture.contentIDs))
    let sidecar = try #require(record.splitPerTab)
    #expect(sidecar == fixture.expectedSidecar)
    let unfolded = try #require(record.layout.unfolding(sidecar))
    #expect(unfolded.isConsistent(for: .splitPerTab))
    #expect(unfolded.groupOrder == live.groupOrder)
  }

  @Test func stripsAScriptGroupBeforeFolding() throws {
    let fixture = SplitPerTabPersistenceFixture()
    let scriptPaneID = PaneID()
    let scriptGroupID = PaneGroupID(rawValue: UUID())
    let scriptTabID = TabID()
    let scriptContentID = ContentID()
    var live = fixture.layout()
    live.panes.append(
      Pane(
        id: scriptPaneID,
        tabs: [
          TabItem(
            id: scriptTabID,
            title: "Setup",
            content: ContentSnapshot(
              id: scriptContentID,
              state: .terminal(
                TerminalContentState(
                  workingDirectory: nil,
                  launch: LaunchOverride(command: "./setup.sh", bypassZmx: true)
                )
              )
            ),
            isLocked: true
          )
        ],
        selectedTabID: scriptTabID
      )
    )
    live.parkedGroups.append(
      PaneGroup(id: scriptGroupID, tree: SplitTree(view: scriptPaneID), focusedPaneID: scriptPaneID)
    )
    live.groupOrder.append(scriptGroupID)
    #expect(live.isConsistent(for: .splitPerTab))

    let record = LayoutPersistence.record(for: live, runtime: ContentRuntime())

    // Stripping runs on the live shape, so the script's group leaves with its
    // pane; folding first would leave the sidecar naming a stripped tab.
    #expect(!record.layout.allContentIDs.contains(scriptContentID))
    #expect(Set(record.layout.allContentIDs) == Set(fixture.contentIDs))
    #expect(record.layout.isConsistent)
    let sidecar = try #require(record.splitPerTab)
    #expect(sidecar == fixture.expectedSidecar)
    #expect(!sidecar.groupOrder.contains(scriptGroupID))
    #expect(record.layout.unfolding(sidecar) != nil)
  }
}

/// A split-per-tab layout shared by the persistence suites: the active group
/// holds one pane; one parked group holds two panes split right, focus on the
/// second. Every pane holds one tab.
nonisolated struct SplitPerTabPersistenceFixture {
  let activeGroupID = PaneGroupID(rawValue: UUID())
  let parkedGroupID = PaneGroupID(rawValue: UUID())
  let activePaneID = PaneID()
  let parkedPaneIDs = [PaneID(), PaneID()]
  let tabIDs = [TabID(), TabID(), TabID()]
  let contentIDs = [ContentID(), ContentID(), ContentID()]

  var parkedTree: SplitTree<PaneID> {
    let tree = SplitTree<PaneID>(view: parkedPaneIDs[0])
    return (try? tree.inserting(view: parkedPaneIDs[1], at: parkedPaneIDs[0], direction: .right)) ?? tree
  }

  func layout() -> PaneLayout {
    let paneIDs = [activePaneID] + parkedPaneIDs
    let panes = paneIDs.indices.map { index in
      Pane(
        id: paneIDs[index],
        tabs: [
          TabItem(
            id: tabIDs[index],
            title: "Tab \(index)",
            content: ContentSnapshot(
              id: contentIDs[index],
              state: .terminal(TerminalContentState(workingDirectory: "/w\(index)"))
            )
          )
        ],
        selectedTabID: tabIDs[index]
      )
    }
    return PaneLayout(
      tree: SplitTree(view: activePaneID),
      panes: IdentifiedArray(uniqueElements: panes),
      focusedPaneID: activePaneID,
      activeGroupID: activeGroupID,
      parkedGroups: [PaneGroup(id: parkedGroupID, tree: parkedTree, focusedPaneID: parkedPaneIDs[1])],
      groupOrder: [activeGroupID, parkedGroupID]
    )
  }

  /// The sidecar the fold of `layout()` must produce.
  var expectedSidecar: SplitPerTabSidecar {
    SplitPerTabSidecar(
      activeGroupID: activeGroupID,
      groupOrder: [activeGroupID, parkedGroupID],
      parkedGroups: [
        SplitPerTabSidecar.ParkedGroup(
          id: parkedGroupID,
          tree: parkedTree,
          focusedPaneID: parkedPaneIDs[1],
          panes: [
            SplitPerTabSidecar.PaneTab(paneID: parkedPaneIDs[0], tabID: tabIDs[1]),
            SplitPerTabSidecar.PaneTab(paneID: parkedPaneIDs[1], tabID: tabIDs[2]),
          ]
        )
      ]
    )
  }
}
