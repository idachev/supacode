import Clocks
import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsFeature
import SupacodeSettingsShared
import Testing

@testable import supacode

/// Pins the quit save's coverage of hostless layouts: a mode switch converts a
/// hydrated layout that has no content host, and its debounced save is
/// cancelled at quit, so the quit write must still carry the converted shape.
@MainActor
struct WorktreeTerminalManagerQuitSaveTests {
  private let worktreeKey = "/tmp/repo/wt-hostless"

  private func readFile(_ defaults: UserDefaults) -> LayoutsFile? {
    guard let data = defaults.data(forKey: LayoutsFile.userDefaultsKey) else { return nil }
    return try? JSONDecoder().decode(LayoutsFile.self, from: data)
  }

  /// One pane with two tabs: the v2 shape that converts to two groups.
  private func twoTabRecord() -> LayoutRecord {
    let paneID = PaneID()
    let tabs = (1...2).map { index in
      TabItem(
        id: TabID(),
        title: "tab \(index)",
        content: ContentSnapshot(
          id: ContentID(),
          state: .terminal(TerminalContentState(workingDirectory: worktreeKey))
        )
      )
    }
    return LayoutRecord(
      layout: PaneLayout(
        tree: SplitTree(view: paneID),
        panes: [Pane(id: paneID, tabs: IdentifiedArray(uniqueElements: tabs), selectedTabID: tabs[0].id)],
        focusedPaneID: paneID
      )
    )
  }

  @Test(.dependencies) func quitSaveWritesAConvertedHostlessLayoutWithNoDebounceElapsed() async {
    let defaults = UserDefaults.inMemory
    let worktreeID = Worktree.ID(worktreeKey)
    let record = twoTabRecord()
    // The stored v2 record, as an earlier launch left it.
    LayoutsIncrementalWriter(store: LayoutsUserDefaultsStore(defaults: defaults))
      .flushSync(records: [worktreeKey: .record(record)])
    #expect(readFile(defaults)?.worktrees[worktreeKey]?.splitPerTab == nil)

    // A private settings key, so the mode flip never leaks into other tests.
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let settingsFileStorage = SettingsFileStorage.inMemory()

    await withDependencies {
      $0.settingsFileStorage = settingsFileStorage
      $0.settingsFileURL = settingsFileURL
      $0.defaultAppStorage = defaults
      $0.zmxClient = .noop
    } operation: {
      // The debounce sleeps on this clock, which the test never advances.
      let clock = TestClock()
      let manager = WorktreeTerminalManager(runtime: GhosttyRuntime(), clock: clock)
      let (layoutChanges, layoutChanged) = AsyncStream<Worktree.ID>.makeStream()
      let store = Store(
        initialState: AppFeature.State(
          repositories: RepositoriesFeature.State(),
          settings: SettingsFeature.State()
        )
      ) {
        AppFeature()
      } withDependencies: {
        $0.uuid = .incrementing
        $0.contentRuntime = ContentRuntime()
        $0[LayoutContentFactory.self] = LayoutContentFactory { request in
          InertTabContent(id: request.contentID, state: request.content)
        }
        $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
        // The live wiring (supacodeApp): a layout change marks its save dirty.
        $0[LayoutChangeObserver.self] = LayoutChangeObserver(layoutChanged: { worktreeID in
          manager.handleLayoutChanged(for: worktreeID)
          layoutChanged.yield(worktreeID)
        })
      }
      manager.appStore = store

      // Hydrate in the default mode, then switch: the layout has no host.
      store.send(.terminals(.layoutsHydrated(LayoutsFile(worktrees: [worktreeKey: record]))))
      #expect(store.withState { $0.terminals.layouts[id: worktreeID]?.mode } == .tabsPerSplit)
      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock { $0.global.terminalLayoutMode = .splitPerTab }
      manager.handleCommand(.setTerminalLayoutMode(.splitPerTab))

      // The conversion's layout change has marked the save dirty.
      for await changedID in layoutChanges {
        #expect(changedID == worktreeID)
        break
      }
      #expect(store.withState { $0.terminals.layouts[id: worktreeID]?.mode } == .splitPerTab)
      // The debounce has not elapsed, so nothing reached the store yet.
      #expect(readFile(defaults)?.worktrees[worktreeKey]?.splitPerTab == nil)

      // The quit order of `applicationWillTerminate`.
      let cancelledWorktreeIDs = manager.cancelPendingLayoutSaves()
      #expect(cancelledWorktreeIDs == [worktreeID])
      manager.saveAllLayoutSnapshots(extraWorktreeIDs: cancelledWorktreeIDs, agentsBySurface: [:])

      let saved = readFile(defaults)?.worktrees[worktreeKey]
      // The record's layout is the v2 fold (every tab back in one pane) and
      // the sidecar carries the two groups the conversion made.
      #expect(saved?.layout.panes.count == 1)
      #expect(Set(saved?.layout.allContentIDs ?? []) == Set(record.layout.allContentIDs))
      #expect(saved?.splitPerTab?.groupOrder.count == 2)
      #expect(saved?.splitPerTab?.parkedGroups.count == 1)
      layoutChanged.finish()
    }
  }
}
