import Clocks
import ComposableArchitecture
import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

/// The bounded wait a same-network `hello` takes while the LAN endpoint starts
/// (`RemoteHostRouter.finishes(_:within:clock:)`), driven by a `TestClock`.
/// The `hello` name tests build a router on an inert store; nothing starts.
@Suite(.serialized)
struct RemoteAccessHelloWaitTests {
  @MainActor
  @Test func helloUsesTheRenamedName() {
    let router = RemoteHostRouter(
      source: RemoteSnapshotSource(
        store: Store(initialState: AppFeature.State()) { EmptyReducer<AppFeature.State, AppFeature.Action>() },
        terminalManager: WorktreeTerminalManager(runtime: GhosttyRuntime())
      ),
      hostName: "iMac",
      hostID: "5ff84c3b79a7faaa",
      appLabel: nil
    )
    defer { router.stop() }
    #expect(router.helloMessage(for: "c1") == RemoteHelloMessage(host: "iMac", hostId: "5ff84c3b79a7faaa"))
    router.rename(to: "  Office Mac ")
    #expect(router.hostName == "Office Mac")
    #expect(router.helloMessage(for: "c1") == RemoteHelloMessage(host: "Office Mac", hostId: "5ff84c3b79a7faaa"))
  }

  @MainActor
  @Test func aBlankRenameFallsBackToTheComputerName() {
    let router = RemoteHostRouter(
      source: RemoteSnapshotSource(
        store: Store(initialState: AppFeature.State()) { EmptyReducer<AppFeature.State, AppFeature.Action>() },
        terminalManager: WorktreeTerminalManager(runtime: GhosttyRuntime())
      ),
      hostName: "Office Mac",
      hostID: nil,
      appLabel: nil
    )
    defer { router.stop() }
    router.rename(to: " ")
    let expected = RemoteAccessConfig.displayName(configured: nil, computerName: RemoteAccessConfig.computerName)
    #expect(router.helloMessage(for: "c1") == RemoteHelloMessage(host: expected))
  }

  @MainActor
  @Test func helloCarriesTheInjectedAppLabel() {
    let router = RemoteHostRouter(
      source: RemoteSnapshotSource(
        store: Store(initialState: AppFeature.State()) { EmptyReducer<AppFeature.State, AppFeature.Action>() },
        terminalManager: WorktreeTerminalManager(runtime: GhosttyRuntime())
      ),
      hostName: "iMac",
      hostID: "5ff84c3b79a7faaa",
      appLabel: "Supacode 0.11.5 (154) · 2026-11-10 · 2e264f48"
    )
    defer { router.stop() }
    #expect(router.helloMessage(for: "c1").app == "Supacode 0.11.5 (154) · 2026-11-10 · 2e264f48")
  }

  @Test func onlySameNetworkPhonesWaitAndOnlyWhileTheLANStarts() {
    #expect(RemoteHostRouter.helloWaitsForLAN(sameNetwork: true, lanStarting: true))
    #expect(!RemoteHostRouter.helloWaitsForLAN(sameNetwork: true, lanStarting: false))
    #expect(!RemoteHostRouter.helloWaitsForLAN(sameNetwork: false, lanStarting: true))
    #expect(!RemoteHostRouter.helloWaitsForLAN(sameNetwork: false, lanStarting: false))
  }

  @Test func aFinishedStartAnswersWithoutWaitingForTheClock() async {
    let clock = TestClock()
    let start = Task<Void, Never> {}
    let ready = await RemoteHostRouter.finishes(start, within: RemoteHostRouter.helloLANWait, clock: clock)
    #expect(ready)
  }

  @Test func aStartThatEndsBeforeTheDeadlineCountsAsReady() async {
    let clock = TestClock()
    let gate = AsyncStream<Void>.makeStream()
    let start = Task<Void, Never> { for await _ in gate.stream {} }
    let wait = Task { await RemoteHostRouter.finishes(start, within: .seconds(3), clock: clock) }
    await Task.megaYield()
    await clock.advance(by: .seconds(2))
    gate.continuation.finish()
    #expect(await wait.value)
  }

  @Test func aStartStillRunningAtTheDeadlineGivesUp() async {
    let clock = TestClock()
    let gate = AsyncStream<Void>.makeStream()
    let start = Task<Void, Never> { for await _ in gate.stream {} }
    let wait = Task { await RemoteHostRouter.finishes(start, within: .seconds(3), clock: clock) }
    await Task.megaYield()
    await clock.advance(by: .seconds(3))
    #expect(await wait.value == false)
    gate.continuation.finish()
    await start.value
  }

  @Test func aCancelledWaitGivesUpAtOnce() async {
    let clock = TestClock()
    let gate = AsyncStream<Void>.makeStream()
    let start = Task<Void, Never> { for await _ in gate.stream {} }
    let wait = Task { await RemoteHostRouter.finishes(start, within: .seconds(3), clock: clock) }
    await Task.megaYield()
    wait.cancel()
    #expect(await wait.value == false)
    gate.continuation.finish()
    await start.value
  }
}
