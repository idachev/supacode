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
    probeCount: LockIsolated<Int>
  ) -> WorktreeTerminalManager {
    withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { nil },
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

  // MARK: - AgentResumeGate.

  @Test func gateNeverClaimsALiveSession() {
    let live = ContentID()
    var gate = AgentResumeGate(liveSessionNames: [session(for: live)])
    #expect(!gate.claim(live))
    #expect(!gate.claim(live))
    #expect(gate.claimed.isEmpty)
  }

  @Test func gateClaimsADeadSessionOnce() {
    let dead = ContentID()
    var gate = AgentResumeGate(liveSessionNames: [session(for: ContentID())])
    #expect(gate.claim(dead))
    #expect(!gate.claim(dead))
    #expect(gate.claimed == [dead])
  }

  // MARK: - captureLaunchSessionLiveness.

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

  // MARK: - No consume.

  /// The inject only seeds the surface plan; it never writes the content's
  /// state, so the persisted record survives for the next launch.
  @Test func builtRestoredContentKeepsItsRecord() {
    let worktree = Worktree(
      id: WorktreeID("/tmp/resume-fixture/wt"),
      name: "wt",
      detail: "detail",
      workingDirectory: URL(filePath: "/tmp/resume-fixture/wt", directoryHint: .notDirectory),
      repositoryRootURL: URL(filePath: "/tmp/resume-fixture", directoryHint: .notDirectory)
    )
    let record = AgentSessionRecord(agent: "claude", sessionID: "0B5E2C4A-6F7D-4E8A-9B1C-2D3E4F5A6B7C")
    let state = TerminalContentState(workingDirectory: "/tmp/resume-fixture/wt", agentSession: record)
    let builder = TerminalContentBuilder(
      runtime: GhosttyRuntime(),
      worktree: { _ in worktree },
      socketPath: { nil },
      zmxExecutablePath: { nil },
      sourceSurface: { _ in nil },
      wireSurface: { _, _ in },
      environmentExtras: { _ in [:] },
      claimAgentResume: { _ in true }
    )
    let request = ContentRequest(
      worktreeID: worktree.id,
      tabID: TabID(),
      contentID: ContentID(),
      content: .terminal(state),
      origin: .restored
    )

    let content = builder.factory().make(request)

    #expect(content is TerminalContent)
    #expect(content.snapshot().state == .terminal(state))
  }
}
