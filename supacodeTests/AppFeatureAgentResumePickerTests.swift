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
struct AppFeatureAgentResumePickerTests {
  private static let rootPath = "/tmp/agent-resume-picker-repo"

  // MARK: - Once-after-launch present.

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func sheetOpensWhenTheLoadFollowsTheCapture() async {
    let fixture = Fixture()
    let store = makeStore(fixture: fixture, loaded: false)

    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))
    #expect(store.state.agentResumePicker == nil)
    #expect(!store.state.agentResume.didEvaluateAutoPresent)

    await store.send(
      .repositories(
        .repositoriesLoaded([fixture.repository], failures: [], roots: [fixture.rootURL], animated: false)
      )
    )

    #expect(store.state.agentResume.didEvaluateAutoPresent)
    #expect(store.state.agentResumePicker?.rows.ids.elements == fixture.allContentIDs)
    #expect(store.state.agentResumePicker?.selected == Set(fixture.allContentIDs))
    await store.skipInFlightEffects()
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func sheetOpensWhenTheCaptureFollowsTheLoad() async {
    let fixture = Fixture()
    let store = makeStore(fixture: fixture, loaded: false)

    await store.send(
      .repositories(
        .repositoriesLoaded([fixture.repository], failures: [], roots: [fixture.rootURL], animated: false)
      )
    )
    #expect(store.state.agentResumePicker == nil)
    #expect(!store.state.agentResume.didEvaluateAutoPresent)

    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))

    #expect(store.state.agentResumePicker?.rows.ids.elements == fixture.allContentIDs)
    await store.skipInFlightEffects()
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func failedProbeOpensNoSheet() async {
    let store = makeStore(fixture: Fixture())

    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: nil)))

    #expect(store.state.agentResume.didEvaluateAutoPresent)
    #expect(store.state.agentResumePicker == nil)
    await store.finish()
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func emptyPendingOpensNoSheet() async {
    let fixture = Fixture()
    let store = makeStore(fixture: fixture, claimed: Set(fixture.allContentIDs))

    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))

    #expect(store.state.agentResume.didEvaluateAutoPresent)
    #expect(store.state.agentResume.pending.isEmpty)
    #expect(store.state.agentResumePicker == nil)
    await store.finish()
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func sheetDoesNotOpenASecondTime() async {
    let fixture = Fixture()
    let store = makeStore(fixture: fixture)
    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))
    #expect(store.state.agentResumePicker != nil)

    await store.send(.agentResumePicker(.dismiss))
    #expect(store.state.agentResumePicker == nil)
    let renamed = fixture.tabs[1][0]
    await store.send(
      .terminals(.layouts(.element(id: fixture.worktrees[1].id, action: .renameTab(id: renamed.id, title: "New"))))
    )

    #expect(store.state.agentResume.pending.count == fixture.allContentIDs.count)
    #expect(store.state.agentResumePicker == nil)
    await store.skipInFlightEffects()
  }

  // MARK: - Reopen.

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func requestReopensTheSheetWithEveryRowTicked() async {
    let fixture = Fixture()
    let store = makeStore(fixture: fixture)
    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))
    await store.send(.agentResumePicker(.presented(.toggleRow(fixture.allContentIDs[0]))))
    await store.send(.agentResumePicker(.dismiss))

    await store.send(.agentResumePickerRequested)

    #expect(store.state.agentResumePicker?.rows.ids.elements == fixture.allContentIDs)
    #expect(store.state.agentResumePicker?.selected == Set(fixture.allContentIDs))
    await store.finish()
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func requestWithNothingPendingDoesNothing() async {
    let store = makeStore(fixture: Fixture())

    await store.send(.agentResumePickerRequested)

    #expect(store.state.agentResumePicker == nil)
    await store.finish()
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func paletteDelegateRequestsThePicker() async {
    let fixture = Fixture()
    let store = makeStore(fixture: fixture, loaded: false)
    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))
    #expect(store.state.agentResumePicker == nil)

    await store.send(.commandPalette(.delegate(.resumeAgentSessions)))
    await store.receive(\.agentResumePickerRequested)

    #expect(store.state.agentResumePicker?.rows.ids.elements == fixture.allContentIDs)
    await store.skipInFlightEffects()
  }

  // MARK: - Live rows.

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func claimWhileOpenDropsTheRowAndKeepsTheOtherTicks() async {
    let fixture = Fixture()
    let ids = fixture.allContentIDs
    let store = makeStore(fixture: fixture)
    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))
    await store.send(.agentResumePicker(.presented(.toggleRow(ids[2]))))

    await store.send(.terminalEvent(.agentResumeClaimed(ids[0])))

    #expect(store.state.agentResumePicker?.rows.ids.elements == [ids[1], ids[2]])
    #expect(store.state.agentResumePicker?.selected == [ids[1]])
    await store.finish()
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func lastClaimClosesTheSheet() async {
    let fixture = Fixture()
    let store = makeStore(fixture: fixture)
    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))
    #expect(store.state.agentResumePicker != nil)

    for id in fixture.allContentIDs {
      await store.send(.terminalEvent(.agentResumeClaimed(id)))
    }

    #expect(store.state.agentResume.pending.isEmpty)
    #expect(store.state.agentResumePicker == nil)
    await store.finish()
  }

  // MARK: - Resume.

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func resumeSelectedRequestsTheWakeOfTheTickedRows() async {
    let fixture = Fixture()
    let ids = fixture.allContentIDs
    let store = makeStore(fixture: fixture)
    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))
    await store.send(.agentResumePicker(.presented(.toggleRow(ids[1]))))

    await store.send(.agentResumePicker(.presented(.resumeSelectedTapped)))
    await store.receive(\.agentResumePicker.presented.delegate.resumeRequested)
    await store.receive(\.agentResumeWakeRequested, [ids[0], ids[2]])
    await store.receive(\.agentResumePicker.dismiss)

    #expect(store.state.agentResumePicker == nil)
    await store.skipInFlightEffects()
  }

  // MARK: - Support.

  private func makeStore(
    fixture: Fixture,
    loaded: Bool = true,
    claimed: Set<ContentID> = []
  ) -> TestStoreOf<AppFeature> {
    var state = AppFeature.State(repositories: fixture.repositories, settings: SettingsFeature.State())
    state.repositories.isInitialLoadComplete = loaded
    state.terminals.layouts = fixture.layouts
    state.agentResume.claimed = claimed
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
    let rootURL: URL
    let repository: Repository
    let worktrees: [Worktree]
    let tabs: [[TabItem]]
    let layouts: IdentifiedArrayOf<LayoutFeature.State>
    let repositories: RepositoriesFeature.State

    var allContentIDs: [ContentID] { tabs.flatMap { $0.map(\.content.id) } }

    init() {
      let rootPath = AppFeatureAgentResumePickerTests.rootPath
      let rootURL = URL(fileURLWithPath: rootPath)
      let worktrees = ["a", "b"].map { name in
        Worktree(
          id: WorktreeID("\(rootPath)/\(name)"),
          name: name,
          detail: "",
          workingDirectory: URL(fileURLWithPath: "\(rootPath)/\(name)"),
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
      self.rootURL = rootURL
      self.repository = repository
      self.worktrees = worktrees
      self.tabs = tabs
      self.layouts = layouts
      self.repositories = RepositoriesFeature.State(reconciledRepositories: [repository])
    }
  }
}
