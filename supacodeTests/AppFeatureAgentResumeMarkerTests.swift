import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

/// The sidebar marker of a pending agent resume: `refreshAgentResume` sends
/// `.pendingAgentResumeChanged` only to the rows whose marker flips.
@MainActor
struct AppFeatureAgentResumeMarkerTests {
  private static let rootPath = "/tmp/agent-resume-marker-repo"

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func pendingRowMarksItsWorktree() async {
    let fixture = Fixture()
    let store = makeStore(fixture: fixture)
    #expect(marker(store, fixture.worktrees[0]) == false)

    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))
    await settle(store)

    #expect(marker(store, fixture.worktrees[0]) == true)
    #expect(marker(store, fixture.worktrees[1]) == true)
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func claimOfTheLastPendingPaneClearsTheMarker() async {
    let fixture = Fixture()
    let store = makeStore(fixture: fixture)
    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))
    await settle(store)

    // Worktree "b" has one pending pane.
    await store.send(.terminalEvent(.agentResumeClaimed(fixture.tabs[1][0].content.id)))
    await settle(store)

    #expect(marker(store, fixture.worktrees[1]) == false)
    #expect(marker(store, fixture.worktrees[0]) == true)
  }

  /// ЗДС r1 F5: a lazy show claims through the same event, with no picker and
  /// no background wake in between; the row and the marker go the same way.
  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func lazyShowClaimClearsTheRowAndTheMarker() async {
    let fixture = Fixture()
    let store = makeStore(fixture: fixture)
    let shown = fixture.tabs[1][0].content.id
    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))
    await settle(store)
    #expect(store.state.agentResume.wakeQueue.isEmpty)

    await store.send(.terminalEvent(.agentResumeClaimed(shown)))
    await settle(store)

    #expect(store.state.agentResume.pending[id: shown] == nil)
    #expect(!store.state.agentResume.pending.map(\.worktreeID).contains(fixture.worktrees[1].id))
    #expect(marker(store, fixture.worktrees[1]) == false)
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func worktreeWithTwoPendingPanesKeepsTheMarkerAfterOneClaim() async {
    let fixture = Fixture()
    let store = makeStore(fixture: fixture)
    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))
    await settle(store)

    await store.send(.terminalEvent(.agentResumeClaimed(fixture.tabs[0][0].content.id)))
    await settle(store)
    #expect(marker(store, fixture.worktrees[0]) == true)

    await store.send(.terminalEvent(.agentResumeClaimed(fixture.tabs[0][1].content.id)))
    await settle(store)
    #expect(marker(store, fixture.worktrees[0]) == false)
  }

  /// ЗДС r1 F4: a rename updates the row title on the next refresh and leaves
  /// the marker as it is.
  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func renameOfAPendingTabUpdatesTheRowTitleAndKeepsTheMarker() async {
    let fixture = Fixture()
    let store = makeStore(fixture: fixture)
    let renamed = fixture.tabs[1][0]
    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))
    await settle(store)

    await store.send(
      .terminals(.layouts(.element(id: fixture.worktrees[1].id, action: .renameTab(id: renamed.id, title: "Renamed"))))
    )
    await settle(store)

    #expect(store.state.agentResume.pending[id: renamed.content.id]?.tabTitle == "Renamed")
    #expect(marker(store, fixture.worktrees[1]) == true)
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func settingOffClearsEveryMarkerAndOnBringsThemBack() async {
    @Shared(.settingsFile) var settingsFile
    // `@Shared` settings are process-global; put the setting back for later tests.
    defer { $settingsFile.withLock { $0.global.resumeAgentSessionsAfterRestart = true } }
    let fixture = Fixture()
    let store = makeStore(fixture: fixture)
    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))
    await settle(store)

    $settingsFile.withLock { $0.global.resumeAgentSessionsAfterRestart = false }
    var settings = settingsFile.global
    await store.send(.settings(.delegate(.settingsChanged(settings))))
    await settle(store)

    #expect(store.state.agentResume.pending.isEmpty)
    #expect(marker(store, fixture.worktrees[0]) == false)
    #expect(marker(store, fixture.worktrees[1]) == false)

    $settingsFile.withLock { $0.global.resumeAgentSessionsAfterRestart = true }
    settings = settingsFile.global
    await store.send(.settings(.delegate(.settingsChanged(settings))))
    await settle(store)

    #expect(marker(store, fixture.worktrees[0]) == true)
    #expect(marker(store, fixture.worktrees[1]) == true)
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func noActionForAnUnchangedRow() {
    let fixture = Fixture()
    var rows = fixture.repositories.sidebarItems
    let pendingA = PendingAgentResume(
      id: fixture.tabs[0][0].content.id,
      worktreeID: fixture.worktrees[0].id,
      tabID: fixture.tabs[0][0].id,
      repositoryName: "Repo",
      worktreeName: "a",
      tabTitle: "a-tab-0",
      agent: "claude",
      sessionID: "session-a"
    )

    // Nothing marked, nothing pending: no flip.
    #expect(AppFeature.pendingAgentResumeMarkerFlips(pending: [], sidebarItems: rows).isEmpty)

    // "a" becomes pending: only "a" flips.
    #expect(
      AppFeature.pendingAgentResumeMarkerFlips(pending: [pendingA], sidebarItems: rows)
        == [fixture.worktrees[0].id: true]
    )

    // "a" already marked and still pending: no flip. "b" marked but not pending: "b" clears.
    rows[id: fixture.worktrees[0].id]?.hasPendingAgentResume = true
    rows[id: fixture.worktrees[1].id]?.hasPendingAgentResume = true
    #expect(
      AppFeature.pendingAgentResumeMarkerFlips(pending: [pendingA], sidebarItems: rows)
        == [fixture.worktrees[1].id: false]
    )

    // A pending row of a worktree absent from the sidebar sends nothing.
    rows[id: fixture.worktrees[1].id]?.hasPendingAgentResume = false
    let absent = PendingAgentResume(
      id: ContentID(),
      worktreeID: WorktreeID("/tmp/elsewhere/x"),
      tabID: TabID(),
      repositoryName: "Other",
      worktreeName: "x",
      tabTitle: "x",
      agent: "codex",
      sessionID: "session-x"
    )
    #expect(AppFeature.pendingAgentResumeMarkerFlips(pending: [pendingA, absent], sidebarItems: rows).isEmpty)
  }

  // MARK: - Support.

  /// Waits for the marker flips and folds them into `store.state`. A flip
  /// lands as a received `.pendingAgentResumeChanged`; a non-exhaustive store
  /// shows received state only after a `receive`, `skipReceivedActions` or the
  /// next `send`, never after `finish()`, which also times out silently. The
  /// long timeout only matters under a loaded parallel run; nothing here waits
  /// on a clock.
  private func settle(_ store: TestStoreOf<AppFeature>) async {
    await store.finish(timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
  }

  private func marker(_ store: TestStoreOf<AppFeature>, _ worktree: Worktree) -> Bool? {
    store.state.repositories.sidebarItems[id: worktree.id]?.hasPendingAgentResume
  }

  private func makeStore(fixture: Fixture) -> TestStoreOf<AppFeature> {
    var state = AppFeature.State(repositories: fixture.repositories, settings: SettingsFeature.State())
    state.terminals.layouts = fixture.layouts
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 5_000)
      $0.uuid = .incrementing
      $0.continuousClock = TestClock()
      $0.defaultAppStorage = .inMemory
      $0.contentRuntime = ContentRuntime()
      $0.layoutContentFactory = LayoutContentFactory(
        make: { request in InertTabContent(id: request.contentID, state: request.content) }
      )
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
      $0.terminalClient.send = { _ in }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off
    return store
  }

  /// One local repository with worktrees "a" (two tabs) and "b" (one tab), each
  /// tab holding a terminal with an agent session record.
  private struct Fixture {
    let worktrees: [Worktree]
    let tabs: [[TabItem]]
    let layouts: IdentifiedArrayOf<LayoutFeature.State>
    let repositories: RepositoriesFeature.State

    init() {
      let rootURL = URL(fileURLWithPath: AppFeatureAgentResumeMarkerTests.rootPath)
      let worktrees = ["a", "b"].map { name in
        Worktree(
          id: WorktreeID("\(AppFeatureAgentResumeMarkerTests.rootPath)/\(name)"),
          name: name,
          detail: "",
          workingDirectory: URL(fileURLWithPath: "\(AppFeatureAgentResumeMarkerTests.rootPath)/\(name)"),
          repositoryRootURL: rootURL
        )
      }
      let repository = Repository(
        id: RepositoryID(rootURL.path(percentEncoded: false)),
        rootURL: rootURL,
        name: "Repo",
        worktrees: IdentifiedArray(uniqueElements: worktrees)
      )
      var tabs: [[TabItem]] = []
      var layouts = IdentifiedArrayOf<LayoutFeature.State>()
      for (worktree, count) in zip(worktrees, [2, 1]) {
        let worktreeTabs = (0..<count).map { index in
          TabItem(
            id: TabID(),
            title: "\(worktree.name)-tab-\(index)",
            content: ContentSnapshot(
              id: ContentID(),
              state: .terminal(
                TerminalContentState(
                  workingDirectory: nil,
                  agentSession: AgentSessionRecord(agent: "claude", sessionID: UUID().uuidString.lowercased())
                )
              )
            )
          )
        }
        let paneID = PaneID()
        let layout = PaneLayout(
          tree: SplitTree(view: paneID),
          panes: [Pane(id: paneID, tabs: IdentifiedArray(uniqueElements: worktreeTabs))],
          focusedPaneID: paneID
        )
        tabs.append(worktreeTabs)
        layouts.append(LayoutFeature.State(id: worktree.id, layout: layout))
      }
      self.worktrees = worktrees
      self.tabs = tabs
      self.layouts = layouts
      self.repositories = RepositoriesFeature.State(reconciledRepositories: [repository])
    }
  }
}
