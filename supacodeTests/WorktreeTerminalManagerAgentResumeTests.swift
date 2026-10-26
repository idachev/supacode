import Dependencies
import Foundation
import Testing

@testable import supacode

@MainActor
struct WorktreeTerminalManagerAgentResumeTests {
  /// A manager whose zmx probe serves `listing` (nil = probe failed) and
  /// counts how many times it was asked.
  private func makeManager(
    listing: [ZmxSessionListParser.Entry]?,
    probeCount: LockIsolated<Int>,
    executableURL: URL? = nil
  ) -> WorktreeTerminalManager {
    withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { executableURL },
        isBundled: { true },
        killSession: { _ in },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: {
          probeCount.withValue { $0 += 1 }
          return listing
        }
      )
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
  }

  private func session(for id: ContentID) -> String {
    ZmxSessionID.make(surfaceID: id.rawValue)
  }

  private static let zmxURL = URL(fileURLWithPath: "/tmp/zmx")

  /// The agent resume events emitted so far. Everything before a subscriber is
  /// buffered and replays synchronously into the first stream; a second
  /// `eventStream()` finishes that stream, so draining it never waits.
  private func agentResumeEvents(_ manager: WorktreeTerminalManager) async -> [TerminalClient.Event] {
    let stream = manager.eventStream()
    _ = manager.eventStream()
    var events: [TerminalClient.Event] = []
    for await event in stream {
      switch event {
      case .agentResumeLivenessCaptured, .agentResumeClaimed:
        events.append(event)
      default:
        continue
      }
    }
    return events
  }

  // MARK: - AgentResumeGate.

  @Test func gateNeverClaimsALiveSession() {
    let live = ContentID()
    var gate = AgentResumeGate(liveSessionNames: [session(for: live)])
    let first = gate.claim(live)
    let second = gate.claim(live)
    #expect(!first)
    #expect(!second)
    #expect(gate.claimed.isEmpty)
  }

  @Test func gateClaimsADeadSessionOnce() {
    let dead = ContentID()
    var gate = AgentResumeGate(liveSessionNames: [session(for: ContentID())])
    let first = gate.claim(dead)
    let second = gate.claim(dead)
    #expect(first)
    #expect(!second)
    #expect(gate.claimed == [dead])
  }

  @Test func claimOutcomeReportsWhyAClaimIsRefused() {
    let live = ContentID()
    let dead = ContentID()
    var gate = AgentResumeGate(liveSessionNames: [session(for: live)])
    let liveOutcome = gate.claimOutcome(live)
    let firstDead = gate.claimOutcome(dead)
    let secondDead = gate.claimOutcome(dead)
    #expect(liveOutcome == .live)
    #expect(firstDead == .granted)
    #expect(secondDead == .alreadyClaimed)
    #expect(gate.claimed == [dead])

    // `claim` agrees with `claimOutcome == .granted`.
    var agreeing = AgentResumeGate(liveSessionNames: [session(for: live)])
    let claimLive = agreeing.claim(live)
    let claimDead = agreeing.claim(dead)
    let claimDeadAgain = agreeing.claim(dead)
    #expect(!claimLive)
    #expect(claimDead)
    #expect(!claimDeadAgain)
  }

  // MARK: - captureLaunchSessionLiveness.

  @Test func captureEmitsTheNonStaleLiveNames() async {
    let stale = ContentID()
    let busy = ContentID()
    let probeCount = LockIsolated(0)
    let manager = makeManager(
      listing: [
        .init(name: session(for: stale), clients: nil, isStale: true),
        .init(name: session(for: busy), clients: 1),
      ],
      probeCount: probeCount,
      executableURL: Self.zmxURL
    )

    await manager.captureLaunchSessionLiveness()
    await manager.captureLaunchSessionLiveness()

    #expect(await agentResumeEvents(manager) == [.agentResumeLivenessCaptured(liveSessionNames: [session(for: busy)])])
  }

  @Test func captureEmitsNilWhenTheProbeFails() async {
    let probeCount = LockIsolated(0)
    let manager = makeManager(listing: nil, probeCount: probeCount, executableURL: Self.zmxURL)

    await manager.captureLaunchSessionLiveness()

    #expect(await agentResumeEvents(manager) == [.agentResumeLivenessCaptured(liveSessionNames: nil)])
  }

  /// ЗДС r1 F1: the probe passes, but the seed's budget-gated zmx is missing,
  /// so nothing can resume; the event says so while the gate stays built.
  @Test func captureEmitsNilWhenZmxCannotSpawn() async {
    let probeCount = LockIsolated(0)
    let manager = makeManager(listing: [], probeCount: probeCount, executableURL: nil)

    await manager.captureLaunchSessionLiveness()

    #expect(await agentResumeEvents(manager) == [.agentResumeLivenessCaptured(liveSessionNames: nil)])
    #expect(manager.agentResumeGate?.liveSessionNames.isEmpty == true)
  }

  @Test func onlyAGrantedClaimEmitsTheClaimedEvent() async {
    let live = ContentID()
    let dead = ContentID()
    let sentinel = ContentID()
    let probeCount = LockIsolated(0)
    let manager = makeManager(
      listing: [.init(name: session(for: live), clients: 1)],
      probeCount: probeCount,
      executableURL: Self.zmxURL
    )
    await manager.captureLaunchSessionLiveness()

    #expect(manager.claimAgentResume(dead))
    #expect(!manager.claimAgentResume(dead))
    #expect(!manager.claimAgentResume(live))
    #expect(manager.claimAgentResume(sentinel))

    #expect(
      await agentResumeEvents(manager) == [
        .agentResumeLivenessCaptured(liveSessionNames: [session(for: live)]),
        .agentResumeClaimed(dead),
        .agentResumeClaimed(sentinel),
      ]
    )
  }

  @Test func claimWithoutAGateEmitsNothing() async {
    let probeCount = LockIsolated(0)
    let manager = makeManager(listing: nil, probeCount: probeCount, executableURL: Self.zmxURL)
    await manager.captureLaunchSessionLiveness()

    #expect(!manager.claimAgentResume(ContentID()))

    #expect(await agentResumeEvents(manager) == [.agentResumeLivenessCaptured(liveSessionNames: nil)])
  }

  @Test func captureRunsTheProbeOnceAndBuildsTheGate() async {
    let live = ContentID()
    let probeCount = LockIsolated(0)
    let manager = makeManager(
      listing: [.init(name: session(for: live), clients: 0)],
      probeCount: probeCount
    )

    await manager.captureLaunchSessionLiveness()
    await manager.captureLaunchSessionLiveness()

    #expect(probeCount.value == 1)
    #expect(manager.agentResumeGate?.liveSessionNames == [session(for: live)])
  }

  @Test func captureKeepsTheFirstSnapshotEvenAfterAnAttach() async {
    // A second call (after restored panes attached and upserted their
    // sessions) must not refresh liveness, or every session looks alive.
    let probeCount = LockIsolated(0)
    let manager = makeManager(listing: [], probeCount: probeCount)
    let dead = ContentID()

    await manager.captureLaunchSessionLiveness()
    await manager.captureLaunchSessionLiveness()

    #expect(manager.agentResumeGate?.liveSessionNames.isEmpty == true)
    #expect(manager.claimAgentResume(dead))
  }

  /// Branch r1 F3: a stale socket from an unclean shutdown is listed by
  /// `zmx ls` (`err=ConnectionRefused`) but its session is dead, so its pane
  /// still resumes; an `unreachable` one counts as live.
  @Test func staleListedSessionCountsAsDead() async {
    let stale = ContentID()
    let busy = ContentID()
    let probeCount = LockIsolated(0)
    let manager = makeManager(
      listing: [
        .init(name: session(for: stale), clients: nil, isStale: true),
        .init(name: session(for: busy), clients: nil, isStale: false),
      ],
      probeCount: probeCount
    )

    await manager.captureLaunchSessionLiveness()

    #expect(manager.agentResumeGate?.liveSessionNames == [session(for: busy)])
    #expect(manager.claimAgentResume(stale))
    #expect(!manager.claimAgentResume(busy))
  }

  @Test func failedProbeLeavesNoGateAndNeverResumes() async {
    let probeCount = LockIsolated(0)
    let manager = makeManager(listing: nil, probeCount: probeCount)

    await manager.captureLaunchSessionLiveness()
    await manager.captureLaunchSessionLiveness()

    #expect(probeCount.value == 1)
    #expect(manager.agentResumeGate == nil)
    #expect(!manager.claimAgentResume(ContentID()))
  }

  @Test func claimWithoutCapturedLivenessIsFalse() {
    let probeCount = LockIsolated(0)
    let manager = makeManager(listing: [], probeCount: probeCount)

    #expect(!manager.claimAgentResume(ContentID()))
    #expect(probeCount.value == 0)
  }

  @Test func claimSpendsTheSlotOncePerProcess() async {
    let probeCount = LockIsolated(0)
    let live = ContentID()
    let manager = makeManager(
      listing: [.init(name: session(for: live), clients: 1)],
      probeCount: probeCount
    )
    let dead = ContentID()

    await manager.captureLaunchSessionLiveness()

    #expect(manager.claimAgentResume(dead))
    // A rebuilt content after an unexpected close is a new first spawn; the
    // claimed set still blocks a second inject in this process.
    #expect(!manager.claimAgentResume(dead))
    #expect(!manager.claimAgentResume(live))
  }
}
