import ComposableArchitecture
import Foundation
import IdentifiedCollections
import OrderedCollections
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AgentResumePendingTests {
  private static let record = AgentSessionRecord(agent: "claude", sessionID: "0123456789abcdef-session")

  private static func worktree(_ name: String, host: RemoteHost? = nil) -> Worktree {
    Worktree(
      id: WorktreeID("/tmp/pending-repo/\(name)"),
      name: name,
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/pending-repo/\(name)"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/pending-repo"),
      host: host
    )
  }

  private static func tab(
    _ title: String,
    customTitle: String? = nil,
    record: AgentSessionRecord? = AgentResumePendingTests.record
  ) -> TabItem {
    TabItem(
      id: TabID(),
      title: title,
      customTitle: customTitle,
      content: ContentSnapshot(
        id: ContentID(),
        state: .terminal(TerminalContentState(workingDirectory: nil, agentSession: record))
      )
    )
  }

  /// One layout per worktree; each inner array is one pane's tabs.
  private static func layout(_ worktree: Worktree, panes: [[TabItem]]) -> LayoutFeature.State {
    let built = panes.map { Pane(id: PaneID(), tabs: IdentifiedArray(uniqueElements: $0)) }
    let tree = built.dropFirst().reduce(SplitTree(view: built[0].id)) { tree, pane in
      (try? tree.inserting(view: pane.id, at: built[0].id, direction: .right)) ?? tree
    }
    return LayoutFeature.State(
      id: worktree.id,
      layout: PaneLayout(tree: tree, panes: IdentifiedArray(uniqueElements: built), focusedPaneID: built[0].id)
    )
  }

  private static func compute(
    _ layouts: [LayoutFeature.State],
    worktrees: [Worktree],
    repositoryNames: [Worktree.ID: String] = [:],
    liveness: AgentResumeLiveness = .captured(liveSessionNames: []),
    claimed: Set<ContentID> = [],
    enabled: Bool = true
  ) -> IdentifiedArrayOf<PendingAgentResume> {
    AgentResumePending.compute(
      layouts: IdentifiedArray(uniqueElements: layouts),
      liveness: liveness,
      claimed: claimed,
      enabled: enabled,
      worktree: { id in worktrees.first { $0.id == id } },
      repositoryName: { repositoryNames[$0] ?? "Repo" }
    )
  }

  @Test func tabWithoutARecordIsNotPending() {
    let worktree = Self.worktree("a")
    let rows = Self.compute([Self.layout(worktree, panes: [[Self.tab("plain", record: nil)]])], worktrees: [worktree])
    #expect(rows.isEmpty)
  }

  @Test func settingOffGivesNoRows() {
    let worktree = Self.worktree("a")
    let rows = Self.compute([Self.layout(worktree, panes: [[Self.tab("t")]])], worktrees: [worktree], enabled: false)
    #expect(rows.isEmpty)
  }

  @Test func remoteWorktreeIsNotPending() {
    let worktree = Self.worktree("a", host: RemoteHost(alias: "devbox"))
    let rows = Self.compute([Self.layout(worktree, panes: [[Self.tab("t")]])], worktrees: [worktree])
    #expect(rows.isEmpty)
  }

  @Test func unknownWorktreeIsNotPending() {
    let worktree = Self.worktree("a")
    let rows = Self.compute([Self.layout(worktree, panes: [[Self.tab("t")]])], worktrees: [])
    #expect(rows.isEmpty)
  }

  @Test func liveSessionIsNotPending() {
    let worktree = Self.worktree("a")
    let live = Self.tab("live")
    let dead = Self.tab("dead")
    let liveness = AgentResumeLiveness.captured(
      liveSessionNames: [ZmxSessionID.make(surfaceID: live.content.id.rawValue)]
    )
    let rows = Self.compute(
      [Self.layout(worktree, panes: [[live, dead]])], worktrees: [worktree], liveness: liveness
    )
    #expect(rows.ids == [dead.content.id])
  }

  @Test func claimedContentIsNotPending() {
    let worktree = Self.worktree("a")
    let claimed = Self.tab("claimed")
    let rows = Self.compute(
      [Self.layout(worktree, panes: [[claimed]])], worktrees: [worktree], claimed: [claimed.content.id]
    )
    #expect(rows.isEmpty)
  }

  @Test func probeFailedAndNotCapturedGiveNoRows() {
    let worktree = Self.worktree("a")
    let layouts = [Self.layout(worktree, panes: [[Self.tab("t")]])]
    #expect(Self.compute(layouts, worktrees: [worktree], liveness: .probeFailed).isEmpty)
    #expect(Self.compute(layouts, worktrees: [worktree], liveness: .notCaptured).isEmpty)
  }

  @Test func pendingRowCarriesTheExpectedFields() {
    let worktree = Self.worktree("feature")
    let tab = Self.tab("zsh", customTitle: "Agent work")
    let rows = Self.compute(
      [Self.layout(worktree, panes: [[tab]])], worktrees: [worktree], repositoryNames: [worktree.id: "supacode"]
    )
    #expect(
      rows.elements == [
        PendingAgentResume(
          id: tab.content.id,
          worktreeID: worktree.id,
          tabID: tab.id,
          repositoryName: "supacode",
          worktreeName: "feature",
          tabTitle: "Agent work",
          agent: "claude",
          sessionID: Self.record.sessionID
        )
      ]
    )
    #expect(rows.first?.shortSessionID == "01234567")
  }

  @Test func storedTitleIsUsedWithoutACustomTitle() {
    let worktree = Self.worktree("a")
    let rows = Self.compute([Self.layout(worktree, panes: [[Self.tab("zsh")]])], worktrees: [worktree])
    #expect(rows.first?.tabTitle == "zsh")
  }

  @Test func rowsSortByRepositoryThenWorktreeThenLayoutOrder() {
    let beta = Self.worktree("beta")
    let alpha = Self.worktree("alpha")
    let other = Self.worktree("other")
    let betaTabs = [Self.tab("b-0"), Self.tab("b-1")]
    let alphaFirstPane = [Self.tab("a-0"), Self.tab("a-1")]
    let alphaSecondPane = [Self.tab("a-2")]
    let otherTabs = [Self.tab("o-0")]
    let rows = Self.compute(
      [
        Self.layout(other, panes: [otherTabs]),
        Self.layout(beta, panes: [betaTabs]),
        Self.layout(alpha, panes: [alphaFirstPane, alphaSecondPane]),
      ],
      worktrees: [beta, alpha, other],
      repositoryNames: [beta.id: "Repo", alpha.id: "Repo", other.id: "Zeta"]
    )
    #expect(rows.map(\.tabTitle) == ["a-0", "a-1", "a-2", "b-0", "b-1", "o-0"])
  }
}
