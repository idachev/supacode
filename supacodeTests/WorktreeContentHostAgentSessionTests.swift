import AppKit
import Foundation
import GhosttyKit
import IdentifiedCollections
import Testing

@testable import supacode

/// Agent session updates reach only the host that owns the surface (all hosts
/// share one runtime), and land on the content, live or hibernated.
@MainActor
struct WorktreeContentHostAgentSessionTests {
  private static let record = AgentSessionRecord(agent: "claude", sessionID: "0b7c2f4e-6a1d-4c39-9e57-2d8f1a3b5c60")

  private func makeWorktree(id: String) -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func singleTabLayout(contentID: UUID) -> PaneLayout {
    let paneID = PaneID()
    let tabID = TabID(rawValue: contentID)
    return PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: tabID,
              title: "Tab",
              content: ContentSnapshot(
                id: ContentID(rawValue: contentID),
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            )
          ],
          selectedTabID: tabID
        )
      ],
      focusedPaneID: paneID
    )
  }

  private func makeHost(id: String, layout: PaneLayout, runtime: ContentRuntime) -> WorktreeContentHost {
    let host = WorktreeContentHost(
      worktree: makeWorktree(id: id),
      runtime: runtime,
      clock: ContinuousClock(),
      runSetupScript: false
    )
    host.layout = { layout }
    return host
  }

  /// A terminal content provisioned into `runtime` over a real (non-zmx) surface;
  /// a nil surface would make `provision` refuse it.
  private func provisionTerminalContent(id: UUID, in runtime: ContentRuntime) -> TerminalContent? {
    let content = TerminalContent(
      id: ContentID(rawValue: id),
      makeSurface: { geometry, state, _ in
        let view = GhosttySurfaceView(
          id: id,
          runtime: GhosttyRuntime(),
          workingDirectory: state.workingDirectory.map { URL(fileURLWithPath: $0) },
          initialGeometry: geometry,
          context: GHOSTTY_SURFACE_CONTEXT_TAB
        )
        return TerminalContent.SpawnedSurface(view: view, usesZmx: false)
      },
      initialState: TerminalContentState(workingDirectory: nil)
    )
    guard runtime.provision(content, at: .fallback) else { return nil }
    return content
  }

  private func recordedState(of content: TerminalContent) -> TerminalContentState? {
    guard case .terminal(let state) = content.snapshot().state else { return nil }
    return state
  }

  private func storedSession(of content: TerminalContent) -> AgentSessionRecord? {
    recordedState(of: content)?.agentSession
  }

  @Test func updateThroughTheNonOwningHostIsRefusedAndOnlyTheOwnerIsMarkedDirty() throws {
    let runtime = ContentRuntime()
    let surfaceA = UUID()
    let surfaceB = UUID()
    let hostA = makeHost(id: "/tmp/repo/wt-a", layout: singleTabLayout(contentID: surfaceA), runtime: runtime)
    let hostB = makeHost(id: "/tmp/repo/wt-b", layout: singleTabLayout(contentID: surfaceB), runtime: runtime)
    let content = try #require(provisionTerminalContent(id: surfaceB, in: runtime))
    defer { runtime.remove(content.id, tombstone: false) }

    // B's content sits in the shared runtime, yet A does not own the surface.
    #expect(hostA.updateAgentSession(.started(Self.record), onSurfaceID: surfaceB) == false)
    #expect(storedSession(of: content) == nil)

    var dirty: [Worktree.ID] = []
    WorktreeTerminalManager.routeAgentSessionUpdate(
      .started(Self.record),
      onSurfaceID: surfaceB,
      hosts: [hostA.worktree.id: hostA, hostB.worktree.id: hostB]
    ) { dirty.append($0) }

    #expect(dirty == [hostB.worktree.id])
    #expect(storedSession(of: content) == Self.record)
  }

  @Test func unchangedRecordMarksNothingDirty() throws {
    let runtime = ContentRuntime()
    let surface = UUID()
    let host = makeHost(id: "/tmp/repo/wt-a", layout: singleTabLayout(contentID: surface), runtime: runtime)
    let content = try #require(provisionTerminalContent(id: surface, in: runtime))
    defer { runtime.remove(content.id, tombstone: false) }

    #expect(host.updateAgentSession(.started(Self.record), onSurfaceID: surface))
    var dirty: [Worktree.ID] = []
    WorktreeTerminalManager.routeAgentSessionUpdate(
      .started(Self.record), onSurfaceID: surface, hosts: [host.worktree.id: host]
    ) { dirty.append($0) }
    #expect(dirty.isEmpty)
  }

  @Test func knownSurfaceWithoutRuntimeContentIsRefused() {
    let surface = UUID()
    let host = makeHost(id: "/tmp/repo/wt-a", layout: singleTabLayout(contentID: surface), runtime: ContentRuntime())
    #expect(host.updateAgentSession(.started(Self.record), onSurfaceID: surface) == false)
  }

  @Test func hibernatedContentStillTakesTheUpdate() throws {
    let runtime = ContentRuntime()
    let surface = UUID()
    let host = makeHost(id: "/tmp/repo/wt-a", layout: singleTabLayout(contentID: surface), runtime: runtime)
    let content = try #require(provisionTerminalContent(id: surface, in: runtime))
    defer { runtime.remove(content.id, tombstone: false) }
    content.hibernate()
    #expect(content.renderer == nil)

    #expect(host.updateAgentSession(.started(Self.record), onSurfaceID: surface))
    #expect(storedSession(of: content) == Self.record)
  }

  // MARK: - TerminalContent.applyAgentSession

  @Test func applyAgentSessionFollowsTheUpdateRulesAndReportsChanges() {
    // Never provisioned, so `snapshot()` reports the recorded state.
    let content = TerminalContent(
      id: ContentID(),
      makeSurface: { _, _, _ in nil },
      initialState: TerminalContentState(workingDirectory: "/tmp/repo/wt-a")
    )
    let replacement = AgentSessionRecord(agent: "claude", sessionID: "1c8d3a5f-7b2e-4d4a-8f68-3e9a2b4c6d71")

    #expect(content.applyAgentSession(.started(Self.record)))
    #expect(storedSession(of: content) == Self.record)
    #expect(content.applyAgentSession(.started(Self.record)) == false)
    // Last start wins.
    #expect(content.applyAgentSession(.started(replacement)))
    #expect(storedSession(of: content) == replacement)
    // A late end of the old session does not clear its replacement.
    #expect(content.applyAgentSession(.ended(agent: "claude", sessionID: Self.record.sessionID)) == false)
    #expect(storedSession(of: content) == replacement)
    #expect(content.applyAgentSession(.ended(agent: "claude", sessionID: replacement.sessionID)))
    #expect(storedSession(of: content) == nil)
    // The rest of the recorded state is kept.
    #expect(recordedState(of: content)?.workingDirectory == "/tmp/repo/wt-a")
  }
}
