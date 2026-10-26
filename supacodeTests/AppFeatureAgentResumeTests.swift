import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import OrderedCollections
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AppFeatureAgentResumeTests {
  private static let rootPath = "/tmp/agent-resume-repo"

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func livenessEventCapturesTheGateAndComputesPending() async {
    let fixture = Fixture()
    let store = makeStore(fixture: fixture)

    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))

    #expect(store.state.agentResume.liveness == .captured(liveSessionNames: []))
    #expect(Array(store.state.agentResume.pending.ids) == fixture.allContentIDs)
    #expect(store.state.agentResume.pending.first?.repositoryName == "Repo")
    #expect(store.state.agentResume.pending.first?.worktreeName == "a")
    await store.finish()
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func failedProbeGivesNoPending() async {
    let store = makeStore(fixture: Fixture())

    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: nil)))

    #expect(store.state.agentResume.liveness == .probeFailed)
    #expect(store.state.agentResume.pending.isEmpty)
    await store.finish()
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func claimedEventDropsTheRow() async {
    let fixture = Fixture()
    let store = makeStore(fixture: fixture)
    let claimed = fixture.tabs[0][0].content.id
    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))

    await store.send(.terminalEvent(.agentResumeClaimed(claimed)))

    #expect(store.state.agentResume.claimed == [claimed])
    #expect(!store.state.agentResume.pending.ids.contains(claimed))
    #expect(store.state.agentResume.pending.count == fixture.allContentIDs.count - 1)
    await store.finish()
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func closedTabDropsItsRow() async {
    let fixture = Fixture()
    let store = makeStore(fixture: fixture)
    let closed = fixture.tabs[0][1]
    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))

    await store.send(.terminals(.layouts(.element(id: fixture.worktrees[0].id, action: .closeTab(id: closed.id)))))

    #expect(!store.state.agentResume.pending.ids.contains(closed.content.id))
    #expect(store.state.agentResume.pending.count == fixture.allContentIDs.count - 1)
    await store.skipInFlightEffects()
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func detachedLayoutDropsItsRows() async {
    let fixture = Fixture()
    let store = makeStore(fixture: fixture)
    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))

    await store.send(.terminals(.detachLayout(worktreeID: fixture.worktrees[0].id)))

    #expect(store.state.agentResume.pending.map(\.worktreeID) == [fixture.worktrees[1].id])
    await store.skipInFlightEffects()
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func renamedTabUpdatesItsRowTitle() async {
    let fixture = Fixture()
    let store = makeStore(fixture: fixture)
    let renamed = fixture.tabs[1][0]
    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))

    await store.send(
      .terminals(.layouts(.element(id: fixture.worktrees[1].id, action: .renameTab(id: renamed.id, title: "Renamed"))))
    )

    #expect(store.state.agentResume.pending[id: renamed.content.id]?.tabTitle == "Renamed")
    await store.skipInFlightEffects()
  }

  @Test func ungatedLayoutActionDoesNotRefresh() {
    let action = AppFeature.Action.terminals(.layouts(.element(id: WorktreeID("/tmp/x"), action: .equalizePanes)))
    #expect(!AppFeature.affectsAgentResume(action))
    #expect(AppFeature.affectsAgentResume(.terminalEvent(.agentResumeClaimed(ContentID()))))
  }

  // MARK: - Support.

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

    var allContentIDs: [ContentID] { tabs.flatMap { $0.map(\.content.id) } }

    init() {
      let rootURL = URL(fileURLWithPath: AppFeatureAgentResumeTests.rootPath)
      let worktrees = ["a", "b"].map { name in
        Worktree(
          id: WorktreeID("\(AppFeatureAgentResumeTests.rootPath)/\(name)"),
          name: name,
          detail: "",
          workingDirectory: URL(fileURLWithPath: "\(AppFeatureAgentResumeTests.rootPath)/\(name)"),
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
