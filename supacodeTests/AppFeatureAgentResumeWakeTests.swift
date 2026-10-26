import ComposableArchitecture
import ConcurrencyExtras
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import OrderedCollections
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

/// The background wake queue: `.agentResumeWakeRequested` dispatches the first
/// pending pane at once, staggers the rest by `AgentResumePending.wakeStagger`
/// on the injected clock, re-checks pending on every tick, and a new request
/// replaces the queue and cancels the earlier timer.
@MainActor
struct AppFeatureAgentResumeWakeTests {
  private static let rootPath = "/tmp/agent-resume-wake-repo"

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func wakesEachPendingPaneOneStaggerApart() async {
    let fixture = Fixture()
    let clock = TestClock()
    let sent = LockIsolated<[TabID]>([])
    let store = await makeLoadedStore(fixture: fixture, clock: clock, sent: sent)
    let (first, second, third) = (fixture.tabs[0], fixture.tabs[1], fixture.tabs[2])

    await store.send(.agentResumeWakeRequested([first.content.id, second.content.id, third.content.id]))
    await store.receive(\.agentResumeWakeTick)
    await Task.megaYield()
    #expect(sent.value == [first.id])

    await clock.advance(by: AgentResumePending.wakeStagger - .milliseconds(1))
    #expect(sent.value == [first.id])

    await clock.advance(by: .milliseconds(1))
    await store.receive(\.agentResumeWakeTick)
    await Task.megaYield()
    #expect(sent.value == [first.id, second.id])

    await clock.advance(by: AgentResumePending.wakeStagger)
    await store.receive(\.agentResumeWakeTick)
    await Task.megaYield()
    #expect(sent.value == [first.id, second.id, third.id])
    #expect(store.state.agentResume.wakeQueue.isEmpty)
    await store.finish()
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func claimedPaneIsSkippedWithoutWaiting() async {
    let fixture = Fixture()
    let clock = TestClock()
    let sent = LockIsolated<[TabID]>([])
    let store = await makeLoadedStore(fixture: fixture, clock: clock, sent: sent)
    let (first, second, third) = (fixture.tabs[0], fixture.tabs[1], fixture.tabs[2])

    await store.send(.agentResumeWakeRequested([first.content.id, second.content.id, third.content.id]))
    await store.receive(\.agentResumeWakeTick)
    await Task.megaYield()
    #expect(sent.value == [first.id])

    // A lazy show claims the second pane during the stagger: its tick skips straight to the third.
    await store.send(.terminalEvent(.agentResumeClaimed(second.content.id)))
    #expect(store.state.agentResume.pending[id: second.content.id] == nil)

    await clock.advance(by: AgentResumePending.wakeStagger)
    await store.receive(\.agentResumeWakeTick)
    await store.receive(\.agentResumeWakeTick)
    await Task.megaYield()
    #expect(sent.value == [first.id, third.id])
    #expect(store.state.agentResume.wakeQueue.isEmpty)
    await store.finish()
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func lastIDIsDispatchedWithoutATimer() async {
    let fixture = Fixture()
    let clock = TestClock()
    let sent = LockIsolated<[TabID]>([])
    let store = await makeLoadedStore(fixture: fixture, clock: clock, sent: sent)
    let first = fixture.tabs[0]

    await store.send(.agentResumeWakeRequested([first.content.id]))
    await store.receive(\.agentResumeWakeTick)
    await Task.megaYield()

    #expect(sent.value == [first.id])
    #expect(store.state.agentResume.wakeQueue.isEmpty)
    // No stagger timer is left in flight for the last id.
    await store.finish()
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func newRequestReplacesTheQueueAndCancelsItsTimer() async {
    let fixture = Fixture()
    let clock = TestClock()
    let sent = LockIsolated<[TabID]>([])
    let store = await makeLoadedStore(fixture: fixture, clock: clock, sent: sent)
    let (first, second, third) = (fixture.tabs[0], fixture.tabs[1], fixture.tabs[2])

    await store.send(.agentResumeWakeRequested([first.content.id, second.content.id]))
    await store.receive(\.agentResumeWakeTick)
    await Task.megaYield()
    #expect(sent.value == [first.id])

    await store.send(.agentResumeWakeRequested([third.content.id]))
    await store.receive(\.agentResumeWakeTick)
    await Task.megaYield()
    #expect(sent.value == [first.id, third.id])

    // The old queue's timer was cancelled: nothing more after the stagger.
    await clock.advance(by: AgentResumePending.wakeStagger)
    await Task.megaYield()
    #expect(sent.value == [first.id, third.id])
    await store.finish()
  }

  @Test(.dependencies, .dependency(\.defaultAppStorage, .inMemory))
  func idThatIsNotPendingSendsNothing() async {
    let fixture = Fixture()
    let clock = TestClock()
    let sent = LockIsolated<[TabID]>([])
    let store = await makeLoadedStore(fixture: fixture, clock: clock, sent: sent)

    await store.send(.agentResumeWakeRequested([ContentID()]))
    await store.receive(\.agentResumeWakeTick)
    await store.receive(\.agentResumeWakeTick)
    await Task.megaYield()

    #expect(sent.value.isEmpty)
    await store.finish()
  }

  @Test func wakeActionsDoNotAffectTheMenuSnapshot() {
    #expect(!AppFeature.Action.agentResumeWakeRequested([ContentID()]).affectsWorktreeMenuSnapshot)
    #expect(!AppFeature.Action.agentResumeWakeTick.affectsWorktreeMenuSnapshot)
  }

  // MARK: - Support.

  /// A store whose gate is captured with nothing live, so every fixture tab is
  /// pending. Records the tab of every background wake command it sends.
  private func makeLoadedStore(
    fixture: Fixture,
    clock: TestClock<Duration>,
    sent: LockIsolated<[TabID]>
  ) async -> TestStoreOf<AppFeature> {
    var state = AppFeature.State(repositories: fixture.repositories, settings: SettingsFeature.State())
    state.terminals.layouts = fixture.layouts
    let worktreeID = fixture.worktree.id
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 5_000)
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.defaultAppStorage = .inMemory
      $0.contentRuntime = ContentRuntime()
      $0.layoutContentFactory = LayoutContentFactory(
        make: { request in InertTabContent(id: request.contentID, state: request.content) }
      )
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
      $0.terminalClient.send = { command in
        guard case .wakeTabInBackground(let worktree, let tabID) = command else { return }
        #expect(worktree.id == worktreeID)
        sent.withValue { $0.append(tabID) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off
    await store.send(.terminalEvent(.agentResumeLivenessCaptured(liveSessionNames: [])))
    #expect(Array(store.state.agentResume.pending.ids) == fixture.tabs.map(\.content.id))
    return store
  }

  /// One local worktree with three tabs in one pane, each a terminal with an
  /// agent session record.
  private struct Fixture {
    let worktree: Worktree
    let tabs: [TabItem]
    let layouts: IdentifiedArrayOf<LayoutFeature.State>
    let repositories: RepositoriesFeature.State

    init() {
      let rootURL = URL(fileURLWithPath: AppFeatureAgentResumeWakeTests.rootPath)
      let worktree = Worktree(
        id: WorktreeID("\(AppFeatureAgentResumeWakeTests.rootPath)/a"),
        name: "a",
        detail: "",
        workingDirectory: URL(fileURLWithPath: "\(AppFeatureAgentResumeWakeTests.rootPath)/a"),
        repositoryRootURL: rootURL
      )
      let repository = Repository(
        id: RepositoryID(rootURL.path(percentEncoded: false)),
        rootURL: rootURL,
        name: "Repo",
        worktrees: [worktree]
      )
      let tabs = (0..<3).map { index in
        TabItem(
          id: TabID(),
          title: "tab-\(index)",
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
        panes: [Pane(id: paneID, tabs: IdentifiedArray(uniqueElements: tabs))],
        focusedPaneID: paneID
      )
      self.worktree = worktree
      self.tabs = tabs
      self.layouts = [LayoutFeature.State(id: worktree.id, layout: layout)]
      self.repositories = RepositoriesFeature.State(reconciledRepositories: [repository])
    }
  }
}
