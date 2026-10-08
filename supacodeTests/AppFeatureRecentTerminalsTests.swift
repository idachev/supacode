import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared
import Testing

@testable import SupacodeSettingsFeature
@testable import supacode

@MainActor
struct AppFeatureRecentTerminalsTests {
  private static let rootPath = "/tmp/recent-repo"
  private static let now = Date(timeIntervalSince1970: 5_000)

  // MARK: - Ordering and filtering.

  @Test(.dependency(\.defaultAppStorage, .inMemory)) func itemsSortByAccessThenWorktreeRecencyThenSidebarOrder() {
    let fixture = Fixture(worktreeNames: ["a", "b", "c", "d"], tabsPerWorktree: [2, 1, 1, 1])
    var repositories = fixture.repositories
    // c then a are recent worktrees; d never was, so it falls to sidebar order.
    repositories.worktreeMRU = [fixture.worktrees[2].id, fixture.worktrees[0].id]
    let access = [
      fixture.tabs[0][1].id.rawValue.uuidString: 200.0,
      fixture.tabs[1][0].id.rawValue.uuidString: 100.0,
    ]

    let items = RecentTerminals.items(
      from: repositories,
      layouts: fixture.layouts,
      access: access,
      resolveTitle: \.title,
      isDormant: { _ in false }
    )

    #expect(
      items.map(\.title) == ["a-tab-1", "b-tab-0", "c-tab-0", "a-tab-0", "d-tab-0"]
    )
    #expect(items.map(\.priorityTier) == [0, 1, 2, 3, 4])
    #expect(items.first?.subtitle == "Repo / a")
    #expect(items.first?.kind == .terminalTab(fixture.worktrees[0].id, fixture.tabs[0][1].id))
  }

  @Test(.dependency(\.defaultAppStorage, .inMemory))
  func itemsExcludeArchivedAndBlockingTabsAndMarkDormantAndCurrent() {
    let fixture = Fixture(worktreeNames: ["a", "b"], tabsPerWorktree: [1, 1])
    var repositories = fixture.repositories
    repositories.selection = .worktree(fixture.worktrees[0].id)
    repositories.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: fixture.worktrees[1].id,
        in: fixture.repository.id,
        bucket: .archived,
        item: .init(archivedAt: Date(timeIntervalSince1970: 1_000))
      )
    }
    var layouts = fixture.layouts
    // A blocking-script tab bypasses zmx: no session to list.
    let blocking = TabItem(
      id: TabID(), title: "script",
      content: ContentSnapshot(
        id: ContentID(),
        state: .terminal(TerminalContentState(workingDirectory: nil, launch: LaunchOverride(bypassZmx: true)))
      )
    )
    let paneID = layouts[id: fixture.worktrees[0].id]!.layout.panes[0].id
    layouts[id: fixture.worktrees[0].id]?.layout.panes[id: paneID]?.tabs.append(blocking)
    let dormantTabID = fixture.tabs[0][0].id

    let items = RecentTerminals.items(
      from: repositories,
      layouts: layouts,
      access: [:],
      resolveTitle: \.title,
      isDormant: { $0.id == dormantTabID }
    )

    #expect(items.map(\.title) == ["a-tab-0"])
    #expect(items.first?.subtitle == "Repo / a · Dormant")
    #expect(items.first?.isCurrentWorktree == true)
  }

  // MARK: - Access recording.

  @Test(.dependency(\.defaultAppStorage, .inMemory)) func tabSwitchInSelectedWorktreeRecordsAccess() async {
    let fixture = Fixture(worktreeNames: ["a"], tabsPerWorktree: [2])
    let store = makeStore(fixture: fixture, selected: fixture.worktrees[0].id)
    let target = fixture.tabs[0][1].id

    await store.send(.terminals(.layouts(.element(id: fixture.worktrees[0].id, action: .selectTab(id: target)))))
    await store.finish()

    @Shared(.recentTerminalTabAccess) var access
    #expect(access == [target.rawValue.uuidString: Self.now.timeIntervalSince1970])
  }

  @Test(.dependency(\.defaultAppStorage, .inMemory)) func tabSwitchInUnselectedWorktreeDoesNotRecord() async {
    let fixture = Fixture(worktreeNames: ["a", "b"], tabsPerWorktree: [1, 2])
    let store = makeStore(fixture: fixture, selected: fixture.worktrees[0].id)

    await store.send(
      .terminals(.layouts(.element(id: fixture.worktrees[1].id, action: .selectTab(id: fixture.tabs[1][1].id))))
    )
    await store.finish()

    @Shared(.recentTerminalTabAccess) var access
    #expect(access.isEmpty)
  }

  @Test(.dependency(\.defaultAppStorage, .inMemory)) func worktreeSelectionRecordsItsCurrentTab() async {
    let fixture = Fixture(worktreeNames: ["a", "b"], tabsPerWorktree: [1, 1])
    let store = makeStore(fixture: fixture, selected: fixture.worktrees[1].id)

    await store.send(.repositories(.delegate(.selectedWorktreeChanged(fixture.worktrees[1]))))
    await store.finish()

    @Shared(.recentTerminalTabAccess) var access
    #expect(access == [fixture.tabs[1][0].id.rawValue.uuidString: Self.now.timeIntervalSince1970])
  }

  @Test(.dependency(\.defaultAppStorage, .inMemory)) func newTabRecordsAccess() async {
    let fixture = Fixture(worktreeNames: ["a"], tabsPerWorktree: [1])
    let store = makeStore(fixture: fixture, selected: fixture.worktrees[0].id)
    let paneID = fixture.layouts[0].layout.panes[0].id
    let newTabID = TabID()

    await store.send(
      .terminals(
        .layouts(
          .element(
            id: fixture.worktrees[0].id,
            action: .newTab(
              inPane: paneID,
              spec: NewTabSpec(
                tabID: newTabID,
                title: "new",
                content: .terminal(TerminalContentState(workingDirectory: nil)),
                geometry: .fallback
              )
            )
          )
        )
      )
    )
    await store.finish()

    @Shared(.recentTerminalTabAccess) var access
    #expect(access == [newTabID.rawValue.uuidString: Self.now.timeIntervalSince1970])
  }

  @Test(.dependency(\.defaultAppStorage, .inMemory)) func confirmedCloseRecordsTheSelectedNeighbour() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .always }
    let fixture = Fixture(worktreeNames: ["a"], tabsPerWorktree: [2])
    let worktreeID = fixture.worktrees[0].id
    let closed = fixture.tabs[0][0].id
    let neighbour = fixture.tabs[0][1].id
    @Shared(.recentTerminalTabAccess) var access
    $access.withLock { $0 = [neighbour.rawValue.uuidString: 1] }
    let store = makeStore(fixture: fixture, selected: worktreeID)

    let closedContentID = fixture.tabs[0][0].content.id
    await store.send(
      .terminals(
        .layouts(.element(id: worktreeID, action: .contentRequestedClose(content: closedContentID, scope: .tab)))
      )
    )
    #expect(store.state.terminals.layouts[id: worktreeID]?.alert != nil)
    await store.send(
      .terminals(.layouts(.element(id: worktreeID, action: .alert(.presented(.confirmClose(tabs: [closed]))))))
    )
    await store.finish()

    #expect(store.state.terminals.layouts[id: worktreeID]?.layout.panes[0].selectedTabID == neighbour)
    #expect(access == [neighbour.rawValue.uuidString: Self.now.timeIntervalSince1970])
  }

  @Test(.dependency(\.defaultAppStorage, .inMemory)) func zoomingAnUnfocusedPaneRecordsItsTab() async {
    let fixture = Fixture(worktreeNames: ["a"], tabsPerWorktree: [1])
    let worktreeID = fixture.worktrees[0].id
    let originalPaneID = fixture.layouts[0].layout.panes[0].id
    let store = makeStore(fixture: fixture, selected: worktreeID)
    await store.send(
      .terminals(
        .layouts(
          .element(
            id: worktreeID,
            action: .splitPane(
              id: originalPaneID,
              direction: .right,
              spec: NewTabSpec(
                tabID: TabID(),
                title: "split",
                content: .terminal(TerminalContentState(workingDirectory: nil)),
                geometry: .fallback
              )
            )
          )
        )
      )
    )
    await store.send(.terminals(.layouts(.element(id: worktreeID, action: .focusPane(.pane(originalPaneID))))))
    let splitPane = store.state.terminals.layouts[id: worktreeID]!.layout.panes.first { $0.id != originalPaneID }!
    @Shared(.recentTerminalTabAccess) var access
    $access.withLock { $0 = [:] }

    await store.send(.terminals(.layouts(.element(id: worktreeID, action: .toggleZoom(paneID: splitPane.id)))))
    await store.finish()

    #expect(access == [splitPane.selectedTabID!.rawValue.uuidString: Self.now.timeIntervalSince1970])
  }

  // MARK: - Pruning.

  @Test(.dependency(\.defaultAppStorage, .inMemory)) func closingTabPrunesItsEntry() async {
    let fixture = Fixture(worktreeNames: ["a"], tabsPerWorktree: [2])
    let kept = fixture.tabs[0][0].id
    let closed = fixture.tabs[0][1].id
    @Shared(.recentTerminalTabAccess) var access
    $access.withLock {
      $0 = [kept.rawValue.uuidString: 1, closed.rawValue.uuidString: 2, UUID().uuidString: 3]
    }
    let store = makeStore(fixture: fixture, selected: fixture.worktrees[0].id)

    await store.send(.terminals(.layouts(.element(id: fixture.worktrees[0].id, action: .closeTab(id: closed)))))
    await store.finish()

    #expect(Set(access.keys) == [kept.rawValue.uuidString])
  }

  // MARK: - Activation.

  @Test(.dependency(\.defaultAppStorage, .inMemory)) func activationSelectsWorktreeAndExactTab() async {
    let fixture = Fixture(worktreeNames: ["a", "b"], tabsPerWorktree: [1, 2])
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = makeStore(fixture: fixture, selected: fixture.worktrees[0].id, sent: sent)
    let worktree = fixture.worktrees[1]
    let tabID = fixture.tabs[1][1].id

    await store.send(.commandPalette(.delegate(.selectTerminalTab(worktree.id, tabID))))
    await store.receive(\.repositories.selectWorktree)
    await store.finish()

    #expect(store.state.repositories.selectedWorktreeID == worktree.id)
    #expect(store.state.terminals.layouts[id: worktree.id]?.layout.panes[0].selectedTabID == tabID)
    #expect(sent.value.contains(.selectTab(worktree, tabID: tabID)))
    // The jump stamps the target tab, never the worktree's previously selected one.
    @Shared(.recentTerminalTabAccess) var access
    #expect(Set(access.keys) == [tabID.rawValue.uuidString])
  }

  @Test(.dependency(\.defaultAppStorage, .inMemory))
  func paletteActivationOfTerminalRowDelegatesWithoutCommandRecency() async {
    let worktreeID = Worktree.ID("\(Self.rootPath)/a")
    let tabID = TabID()
    let item = CommandPaletteItem(
      id: "terminal.\(tabID.rawValue.uuidString)",
      title: "shell",
      subtitle: "Repo / a",
      kind: .terminalTab(worktreeID, tabID)
    )
    let store = TestStore(
      initialState: CommandPaletteFeature.State(isPresented: true, mode: .recentTerminals)
    ) {
      CommandPaletteFeature()
    }

    await store.send(.activateItem(item)) {
      $0.isPresented = false
      $0.mode = .commands
    }
    await store.receive(\.delegate.selectTerminalTab)
  }

  // MARK: - Helpers.

  private func makeStore(
    fixture: Fixture,
    selected: Worktree.ID,
    sent: LockIsolated<[TerminalClient.Command]> = LockIsolated([])
  ) -> TestStoreOf<AppFeature> {
    var repositories = fixture.repositories
    repositories.selection = .worktree(selected)
    var state = AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    state.terminals.layouts = fixture.layouts
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Self.now
      $0.uuid = .incrementing
      $0.contentRuntime = ContentRuntime()
      $0.layoutContentFactory = LayoutContentFactory(
        make: { request in InertTabContent(id: request.contentID, state: request.content) }
      )
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off
    return store
  }

  /// One repository with the named worktrees in sidebar order, each holding a
  /// single pane with `tabsPerWorktree[i]` tabs titled "<name>-tab-<n>".
  private struct Fixture {
    let repository: Repository
    let worktrees: [Worktree]
    let tabs: [[TabItem]]
    let layouts: IdentifiedArrayOf<LayoutFeature.State>
    let repositories: RepositoriesFeature.State

    init(worktreeNames: [String], tabsPerWorktree: [Int]) {
      let rootURL = URL(fileURLWithPath: AppFeatureRecentTerminalsTests.rootPath)
      let worktrees = worktreeNames.map { name in
        Worktree(
          id: WorktreeID("\(AppFeatureRecentTerminalsTests.rootPath)/\(name)"),
          name: name,
          detail: "",
          workingDirectory: URL(fileURLWithPath: "\(AppFeatureRecentTerminalsTests.rootPath)/\(name)"),
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
      for (worktree, count) in zip(worktrees, tabsPerWorktree) {
        let worktreeTabs = (0..<count).map { index in
          TabItem(
            id: TabID(),
            title: "\(worktree.name)-tab-\(index)",
            content: ContentSnapshot(id: ContentID(), state: .terminal(TerminalContentState(workingDirectory: nil)))
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
      self.repository = repository
      self.worktrees = worktrees
      self.tabs = tabs
      self.layouts = layouts
      self.repositories = RepositoriesFeature.State(reconciledRepositories: [repository])
    }
  }
}
