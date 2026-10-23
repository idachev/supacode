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
/// hydrated layout that has no content host, and its debounced save (or the
/// flush it already started) is cancelled at quit, so the quit write must still
/// carry the converted shape.
@MainActor
struct WorktreeTerminalManagerQuitSaveTests {
  private static let worktreeKey = "/tmp/repo/wt-hostless"

  /// In-memory defaults that can hold the next incremental flush inside its
  /// read of the layouts key and then drop its write, the way a flush that has
  /// not landed when the process exits is lost.
  private nonisolated final class HoldingDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var isHolding = false
    private var dropsNextWrite = false
    private let release = DispatchSemaphore(value: 0)
    private var onHold: (@Sendable () -> Void)?

    /// Holds the next read of the layouts key until `releaseHeldFlush()`, calls
    /// `onHold` once the read is held, and drops that flush's write.
    func holdNextFlush(onHold: @escaping @Sendable () -> Void) {
      lock.withLock {
        isHolding = true
        self.onHold = onHold
      }
    }

    func releaseHeldFlush() {
      release.signal()
    }

    override func data(forKey defaultName: String) -> Data? {
      if defaultName == LayoutsFile.userDefaultsKey {
        let onHold: (@Sendable () -> Void)? = lock.withLock {
          guard isHolding else { return nil }
          isHolding = false
          dropsNextWrite = true
          defer { self.onHold = nil }
          return self.onHold
        }
        if let onHold {
          onHold()
          release.wait()
        }
      }
      return super.data(forKey: defaultName)
    }

    override func set(_ value: Any?, forKey defaultName: String) {
      if defaultName == LayoutsFile.userDefaultsKey {
        let drops = lock.withLock {
          defer { dropsNextWrite = false }
          return dropsNextWrite
        }
        if drops { return }
      }
      super.set(value, forKey: defaultName)
    }
  }

  private struct Harness {
    let manager: WorktreeTerminalManager
    /// Retained here: the manager holds its store weakly.
    let store: Store<AppFeature.State, AppFeature.Action>
    let clock: TestClock<Duration>
    let record: LayoutRecord
  }

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
          state: .terminal(TerminalContentState(workingDirectory: Self.worktreeKey))
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

  /// Stores a v2 record, hydrates it with no content host, switches the mode to
  /// split-per-tab and waits until the conversion has marked the save dirty.
  /// Runs inside the caller's dependency scope (private settings key, defaults).
  private func makeConvertedHostlessHarness(defaults: UserDefaults) async -> Harness {
    let worktreeID = Worktree.ID(Self.worktreeKey)
    let record = twoTabRecord()
    // The stored v2 record, as an earlier launch left it.
    LayoutsIncrementalWriter(store: LayoutsUserDefaultsStore(defaults: defaults))
      .flushSync(records: [Self.worktreeKey: .record(record)])
    #expect(readFile(defaults)?.worktrees[Self.worktreeKey]?.splitPerTab == nil)

    // The debounce sleeps on this clock, which only the caller advances.
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
    store.send(.terminals(.layoutsHydrated(LayoutsFile(worktrees: [Self.worktreeKey: record]))))
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
    #expect(readFile(defaults)?.worktrees[Self.worktreeKey]?.splitPerTab == nil)
    return Harness(manager: manager, store: store, clock: clock, record: record)
  }

  /// The record's layout is the v2 fold (every tab back in one pane) and the
  /// sidecar carries the two groups the conversion made.
  private func expectConvertedRecord(in defaults: UserDefaults, original: LayoutRecord) {
    let saved = readFile(defaults)?.worktrees[Self.worktreeKey]
    #expect(saved?.layout.panes.count == 1)
    #expect(Set(saved?.layout.allContentIDs ?? []) == Set(original.layout.allContentIDs))
    #expect(saved?.splitPerTab?.groupOrder.count == 2)
    #expect(saved?.splitPerTab?.parkedGroups.count == 1)
  }

  private func withQuitSaveDependencies(
    defaults: UserDefaults,
    operation: () async -> Void
  ) async {
    // A private settings key, so the mode flip never leaks into other tests.
    await withDependencies {
      $0.settingsFileStorage = .inMemory()
      $0.settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
      $0.defaultAppStorage = defaults
      $0.zmxClient = .noop
    } operation: {
      await operation()
    }
  }

  @Test(.dependencies) func quitSaveWritesAConvertedHostlessLayoutWithNoDebounceElapsed() async {
    let defaults = UserDefaults.inMemory
    await withQuitSaveDependencies(defaults: defaults) {
      let harness = await makeConvertedHostlessHarness(defaults: defaults)

      // The quit order of `applicationWillTerminate`.
      let cancelledWorktreeIDs = harness.manager.cancelPendingLayoutSaves()
      #expect(cancelledWorktreeIDs == [Worktree.ID(Self.worktreeKey)])
      harness.manager.saveAllLayoutSnapshots(extraWorktreeIDs: cancelledWorktreeIDs, agentsBySurface: [:])

      expectConvertedRecord(in: defaults, original: harness.record)
    }
  }

  @Test(.dependencies) func quitSaveWritesAHostlessLayoutWhoseFlushWasInFlight() async {
    let suiteName = "supacode.quit-save.\(UUID().uuidString)"
    guard let defaults = HoldingDefaults(suiteName: suiteName) else {
      Issue.record("Could not create the defaults suite.")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    await withQuitSaveDependencies(defaults: defaults) {
      let harness = await makeConvertedHostlessHarness(defaults: defaults)

      // Let the debounce fire and hold its flush on the writer: the dirty mark
      // is gone and only the in-flight flush task carries the worktree.
      let (held, heldContinuation) = AsyncStream<Void>.makeStream()
      defaults.holdNextFlush { heldContinuation.yield() }
      await harness.clock.advance(by: .seconds(1))
      for await _ in held { break }

      // The quit order of `applicationWillTerminate`.
      let cancelledWorktreeIDs = harness.manager.cancelPendingLayoutSaves()
      #expect(cancelledWorktreeIDs == [Worktree.ID(Self.worktreeKey)])
      // The held flush is lost, as it is when the process exits under it.
      defaults.releaseHeldFlush()
      harness.manager.saveAllLayoutSnapshots(extraWorktreeIDs: cancelledWorktreeIDs, agentsBySurface: [:])

      expectConvertedRecord(in: defaults, original: harness.record)
    }
  }
}
