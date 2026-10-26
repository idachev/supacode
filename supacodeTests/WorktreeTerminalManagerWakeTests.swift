import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import SupacodeSettingsFeature
import SupacodeSettingsShared
import Testing

@testable import supacode

/// `.wakeTabInBackground` creates the worktree's host first (as `splitPane`
/// does), then routes `.wakeTab` to that layout, which provisions the tab's
/// content as `.restored`; a tab that is gone sends nothing.
@MainActor
struct WorktreeTerminalManagerWakeTests {
  private struct Harness {
    let manager: WorktreeTerminalManager
    let store: Store<AppFeature.State, AppFeature.Action>
    let worktree: Worktree
    let tab: TabItem
    let requests: LockIsolated<[ContentRequest]>
  }

  /// A hydrated layout of a never-opened worktree (no host yet), with one
  /// terminal tab, and a factory that records each request.
  private func makeHarness() -> Harness {
    let path = "/tmp/repo/wt-background-wake"
    let worktree = Worktree(
      id: WorktreeID(path),
      name: "wt-background-wake",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: path),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
    let paneID = PaneID()
    let tab = TabItem(
      id: TabID(),
      title: "Agent",
      content: ContentSnapshot(id: ContentID(), state: .terminal(TerminalContentState(workingDirectory: nil)))
    )
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [Pane(id: paneID, tabs: [tab], selectedTabID: tab.id)],
      focusedPaneID: paneID
    )
    let manager = withDependencies {
      $0.settingsFileStorage = .inMemory()
      $0.defaultAppStorage = .inMemory
      $0.zmxClient = .noop
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
    var state = AppFeature.State(repositories: RepositoriesFeature.State(), settings: SettingsFeature.State())
    state.terminals.layouts = [LayoutFeature.State(id: worktree.id, layout: layout)]
    let requests = LockIsolated<[ContentRequest]>([])
    let store = Store(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.contentRuntime = ContentRuntime()
      $0[LayoutContentFactory.self] = LayoutContentFactory { request in
        requests.withValue { $0.append(request) }
        return InertTabContent(id: request.contentID, state: request.content)
      }
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
    }
    manager.appStore = store
    return Harness(manager: manager, store: store, worktree: worktree, tab: tab, requests: requests)
  }

  @Test(.dependencies) func wakeCreatesTheHostAndProvisionsTheTab() {
    let harness = makeHarness()
    #expect(harness.manager.hostIfExists(for: harness.worktree.id) == nil)

    harness.manager.handleCommand(.wakeTabInBackground(harness.worktree, tabID: harness.tab.id))

    #expect(harness.manager.hostIfExists(for: harness.worktree.id) != nil)
    #expect(harness.requests.value.count == 1)
    #expect(harness.requests.value.first?.origin == .restored)
    #expect(harness.requests.value.first?.contentID == harness.tab.content.id)
    #expect(harness.requests.value.first?.tabID == harness.tab.id)
  }

  @Test(.dependencies) func goneTabSendsNoWake() {
    let harness = makeHarness()

    harness.manager.handleCommand(.wakeTabInBackground(harness.worktree, tabID: TabID()))

    #expect(harness.requests.value.isEmpty)
  }
}
