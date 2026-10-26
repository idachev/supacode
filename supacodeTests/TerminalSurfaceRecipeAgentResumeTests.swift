import Dependencies
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct TerminalSurfaceRecipeAgentResumeTests {
  private static let sessionID = "0B5E2C4A-6F7D-4E8A-9B1C-2D3E4F5A6B7C"

  private static func makeWorktree() -> Worktree {
    Worktree(
      id: WorktreeID("/tmp/recipe-resume-fixture/wt"),
      name: "wt",
      detail: "detail",
      workingDirectory: URL(filePath: "/tmp/recipe-resume-fixture/wt", directoryHint: .notDirectory),
      repositoryRootURL: URL(filePath: "/tmp/recipe-resume-fixture", directoryHint: .notDirectory)
    )
  }

  private static func makeRemoteWorktree() -> Worktree {
    let host = RemoteHost(alias: "devbox")
    return Worktree(
      location: .remote(host, workingDirectory: "/home/me/proj", repositoryRoot: "/home/me/proj"),
      kind: .git,
      name: "proj",
      detail: host.sshDestination
    )
  }

  private static func record(_ agent: String, id: String = sessionID) -> AgentSessionRecord {
    AgentSessionRecord(agent: agent, sessionID: id)
  }

  // MARK: - Launch order (Section 5, ii).

  /// A restored pane whose worktree has not loaded yet gets inert content: no
  /// surface is built, so nothing can attach (and upsert its zmx session)
  /// before the launch liveness probe ran.
  @Test func restoredRequestWithoutWorktreeYieldsInertContentAndNoSurface() {
    let calls = LockIsolated<[String]>([])
    let builder = TerminalContentBuilder(
      runtime: GhosttyRuntime(),
      worktree: { _ in nil },
      socketPath: {
        calls.withValue { $0.append("socketPath") }
        return nil
      },
      zmxExecutablePath: {
        calls.withValue { $0.append("zmxExecutablePath") }
        return nil
      },
      sourceSurface: { _ in
        calls.withValue { $0.append("sourceSurface") }
        return nil
      },
      wireSurface: { _, _ in calls.withValue { $0.append("wireSurface") } },
      environmentExtras: { _ in
        calls.withValue { $0.append("environmentExtras") }
        return [:]
      },
      claimAgentResume: { _ in
        calls.withValue { $0.append("claimAgentResume") }
        return true
      }
    )
    let request = ContentRequest(
      worktreeID: Self.makeWorktree().id,
      tabID: TabID(),
      contentID: ContentID(),
      content: .terminal(TerminalContentState(workingDirectory: nil)),
      origin: .restored
    )

    let content = builder.factory().make(request)

    #expect(content is InertTabContent)
    #expect(content.id == request.contentID)
    #expect(calls.value.isEmpty)
  }

  // MARK: - agentResumeInput.

  @Test func agentResumeInputTypesTheCommandForALocalZmxPane() {
    let input = TerminalSurfaceRecipe.agentResumeInput(
      record: Self.record("claude"), worktree: Self.makeWorktree(), zmxAvailable: true, enabled: true)
    #expect(input == "claude --resume '\(Self.sessionID)'\n")
  }

  @Test func agentResumeInputIsNilWhenDisabled() {
    #expect(
      TerminalSurfaceRecipe.agentResumeInput(
        record: Self.record("claude"), worktree: Self.makeWorktree(), zmxAvailable: true, enabled: false) == nil)
  }

  @Test func agentResumeInputIsNilForARemoteWorktree() {
    #expect(
      TerminalSurfaceRecipe.agentResumeInput(
        record: Self.record("claude"), worktree: Self.makeRemoteWorktree(), zmxAvailable: true, enabled: true)
        == nil)
  }

  @Test func agentResumeInputIsNilWithoutZmx() {
    #expect(
      TerminalSurfaceRecipe.agentResumeInput(
        record: Self.record("claude"), worktree: Self.makeWorktree(), zmxAvailable: false, enabled: true) == nil)
  }

  @Test func agentResumeInputIsNilWithoutARecord() {
    #expect(
      TerminalSurfaceRecipe.agentResumeInput(
        record: nil, worktree: Self.makeWorktree(), zmxAvailable: true, enabled: true) == nil)
  }

  // MARK: - agentResumeSkip (the logged reason).

  @Test func agentResumeSkipIsNilWhenTheResumeIsTyped() {
    #expect(
      TerminalSurfaceRecipe.agentResumeSkip(
        record: Self.record("claude"), worktree: Self.makeWorktree(), zmxAvailable: true, enabled: true) == nil)
  }

  private struct SkipCase {
    var record: AgentSessionRecord?
    var worktree: Worktree
    var zmxAvailable = true
    var enabled = true
    var expected: TerminalSurfaceRecipe.AgentResumeSkip
  }

  @Test func agentResumeSkipGivesEachReason() {
    let local = Self.makeWorktree()
    let claude = Self.record("claude")
    let cases = [
      SkipCase(record: nil, worktree: local, expected: .noRecord),
      SkipCase(record: claude, worktree: local, enabled: false, expected: .settingOff),
      SkipCase(record: claude, worktree: Self.makeRemoteWorktree(), expected: .remote),
      SkipCase(record: claude, worktree: local, zmxAvailable: false, expected: .zmxMissing),
      SkipCase(record: Self.record("copilot"), worktree: local, expected: .unsupportedRecord),
      SkipCase(record: Self.record("claude", id: "not-a-uuid"), worktree: local, expected: .unsupportedRecord),
    ]
    for item in cases {
      let skip = TerminalSurfaceRecipe.agentResumeSkip(
        record: item.record, worktree: item.worktree, zmxAvailable: item.zmxAvailable, enabled: item.enabled)
      #expect(skip == item.expected)
      // The input agrees with the skip: no command whenever there is a reason.
      #expect(
        TerminalSurfaceRecipe.agentResumeInput(
          record: item.record, worktree: item.worktree, zmxAvailable: item.zmxAvailable, enabled: item.enabled)
          == nil)
    }
  }

  /// A pane without a record skips as `.noRecord` (logged at debug) even when
  /// another reason also holds, so every info-level skip carries a record.
  @Test func agentResumeSkipReportsAMissingRecordFirst() {
    #expect(
      TerminalSurfaceRecipe.agentResumeSkip(
        record: nil, worktree: Self.makeRemoteWorktree(), zmxAvailable: false, enabled: false) == .noRecord)
  }

  // MARK: - AgentResumeCommand.

  @Test func resumeCommandTextPerAgent() {
    let id = Self.sessionID
    #expect(AgentResumeCommand.initialInput(for: Self.record("claude")) == "claude --resume '\(id)'\n")
    #expect(AgentResumeCommand.initialInput(for: Self.record("codex")) == "codex resume '\(id)'\n")
    #expect(AgentResumeCommand.initialInput(for: Self.record("grok")) == "grok --resume '\(id)'\n")
    #expect(AgentResumeCommand.initialInput(for: Self.record("antigravity")) == "agy --conversation '\(id)'\n")
  }

  @Test func resumeCommandKeepsTheIdCaseAsReceived() {
    let lower = Self.sessionID.lowercased()
    #expect(AgentResumeCommand.initialInput(for: Self.record("codex", id: lower)) == "codex resume '\(lower)'\n")
  }

  @Test func resumeCommandIsNilForUnsupportedAgents() {
    #expect(AgentResumeCommand.initialInput(for: Self.record("copilot")) == nil)
    #expect(AgentResumeCommand.initialInput(for: Self.record("opencode")) == nil)
    #expect(AgentResumeCommand.initialInput(for: Self.record("not-an-agent")) == nil)
  }

  @Test func resumeCommandRejectsANonUUIDSessionID() {
    // A forged id must never reach the shell, quoted or not.
    #expect(AgentResumeCommand.initialInput(for: Self.record("claude", id: "x'; rm -rf ~; '")) == nil)
    #expect(AgentResumeCommand.initialInput(for: Self.record("grok", id: "my session title")) == nil)
    #expect(AgentResumeCommand.initialInput(for: Self.record("claude", id: "")) == nil)
  }

  // MARK: - agentResumeSeed (the makeSurface decision).

  /// Runs the seed decision the way `makeSurface` does, against a real gate.
  private static func seed(
    _ state: TerminalContentState,
    phase: TerminalContent.SpawnPhase = .first,
    origin: ContentOrigin,
    contentID: ContentID,
    gate: LockIsolated<AgentResumeGate>,
    enabled: Bool = true
  ) -> TerminalContentState {
    TerminalSurfaceRecipe.agentResumeSeed(
      state,
      currentState: state,
      phase: phase,
      request: ContentRequest(
        worktreeID: makeWorktree().id,
        tabID: TabID(),
        contentID: contentID,
        content: .terminal(state),
        origin: origin
      ),
      resume: TerminalSurfaceRecipe.AgentResumeContext(
        worktree: makeWorktree(),
        zmxAvailable: true,
        enabled: enabled,
        claim: { id in gate.withValue { $0.claim(id) } }
      )
    )
  }

  private static func deadGate() -> LockIsolated<AgentResumeGate> {
    LockIsolated(AgentResumeGate(liveSessionNames: []))
  }

  @Test func rebootRestoredFirstSpawnInjectsOnceAndKeepsTheRecord() {
    let gate = Self.deadGate()
    let id = ContentID()
    let state = TerminalContentState(workingDirectory: "/tmp/wt", agentSession: Self.record("claude"))

    let first = Self.seed(state, origin: .restored, contentID: id, gate: gate)
    #expect(first.launch?.initialInput == "claude --resume '\(Self.sessionID)'\n")
    #expect(first.agentSession == state.agentSession)
    #expect(first.workingDirectory == "/tmp/wt")

    // A rebuild after an unexpected zmx close is another first `.restored` spawn.
    let rebuilt = Self.seed(state, origin: .restored, contentID: id, gate: gate)
    #expect(rebuilt.launch == nil)
    #expect(rebuilt.agentSession == state.agentSession)
  }

  /// ЗД5 r1 F1: a content that first spawned in this process (here a new tab
  /// with no record yet) and is later rebuilt as `.restored` after its agent
  /// wrote a record must not get the resume typed into its live session.
  @Test func contentFirstSpawnedInThisProcessNeverResumesOnRebuild() {
    let gate = Self.deadGate()
    let id = ContentID()

    let created = Self.seed(TerminalContentState(workingDirectory: nil), origin: .tab, contentID: id, gate: gate)
    #expect(created.launch == nil)

    let withRecord = TerminalContentState(workingDirectory: nil, agentSession: Self.record("claude"))
    let rebuilt = Self.seed(withRecord, origin: .restored, contentID: id, gate: gate)
    #expect(rebuilt.launch == nil)
  }

  @Test func restoredFirstSpawnWithoutRecordSpendsTheSlot() {
    let gate = Self.deadGate()
    let id = ContentID()

    _ = Self.seed(TerminalContentState(workingDirectory: nil), origin: .restored, contentID: id, gate: gate)
    let withRecord = TerminalContentState(workingDirectory: nil, agentSession: Self.record("codex"))
    #expect(Self.seed(withRecord, origin: .restored, contentID: id, gate: gate).launch == nil)
  }

  @Test func rewakeNeverClaimsOrInjects() {
    let gate = Self.deadGate()
    let id = ContentID()
    let state = TerminalContentState(workingDirectory: nil, agentSession: Self.record("claude"))

    #expect(Self.seed(state, phase: .rewake, origin: .restored, contentID: id, gate: gate).launch == nil)
    #expect(gate.value.claimed.isEmpty)
  }

  @Test func liveSessionAtLaunchNeverInjects() {
    let id = ContentID()
    let gate = LockIsolated(AgentResumeGate(liveSessionNames: [ZmxSessionID.make(surfaceID: id.rawValue)]))
    let state = TerminalContentState(workingDirectory: nil, agentSession: Self.record("claude"))

    #expect(Self.seed(state, origin: .restored, contentID: id, gate: gate).launch == nil)
  }

  @Test func disabledSettingNeverInjects() {
    let gate = Self.deadGate()
    let state = TerminalContentState(workingDirectory: nil, agentSession: Self.record("claude"))

    #expect(Self.seed(state, origin: .restored, contentID: ContentID(), gate: gate, enabled: false).launch == nil)
  }
}
