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
}
