import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AppFeatureLaunchOrderTests {
  /// The agent-resume liveness probe must finish before any restored pane can
  /// attach. Worktrees, and so real surfaces, load only from
  /// `.repositories(.task)`, so the probe has to complete before that action.
  @Test(.dependencies) func launchProbeCompletesBeforeRepositoriesTask() async {
    let log = LockIsolated<[String]>([])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.terminalClient.captureLaunchSessionLiveness = {
        // Suspend a few times so a probe racing under `.merge` would lose.
        for _ in 0..<5 { await Task.yield() }
        log.withValue { $0.append("probe") }
      }
      $0.terminalClient.reapOrphanSessions = { _ in }
      $0.repositoryPersistence.loadRoots = {
        log.withValue { $0.append("loadRoots") }
        return []
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.appLaunched)
    await store.receive(\.repositories.task)

    #expect(log.value.first == "probe")
    #expect(log.value.filter { $0 == "probe" }.count == 1)
    await store.skipInFlightEffects()
  }
}
