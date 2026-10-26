import ComposableArchitecture
import Foundation

/// The one pending rule shared by the resume list and the sidebar marker.
nonisolated enum AgentResumePending {
  /// Delay between two background wakes, so many panes never start their
  /// agents (CPU and API calls at startup) all at once.
  static let wakeStagger: Duration = .seconds(1)

  /// The panes that wait for a resume. A pane is pending when the setting is
  /// on, the liveness was captured, its tab holds a terminal with an agent
  /// record, its worktree is known and local, its zmx session was not alive at
  /// launch, and it has not claimed its resume slot. Rows are ordered by
  /// repository name, then worktree name, then layout order of panes and tabs.
  /// Main actor: it reads the `@ObservableState` layouts, whose accessors are
  /// main-actor isolated.
  @MainActor
  static func compute(
    layouts: IdentifiedArrayOf<LayoutFeature.State>,
    liveness: AgentResumeLiveness,
    claimed: Set<ContentID>,
    enabled: Bool,
    worktree: (Worktree.ID) -> Worktree?,
    repositoryName: (Worktree.ID) -> String?
  ) -> IdentifiedArrayOf<PendingAgentResume> {
    guard enabled, case .captured(let liveSessionNames) = liveness else { return [] }
    var groups: [[PendingAgentResume]] = []
    for layout in layouts {
      // An unknown worktree cannot spawn and its local / remote is not known.
      guard let worktree = worktree(layout.id), worktree.host == nil else { continue }
      let repository = repositoryName(layout.id) ?? ""
      var rows: [PendingAgentResume] = []
      // `panes` is flat across every group, in layout order.
      for pane in layout.layout.panes {
        for tab in pane.tabs {
          guard case .terminal(let terminal) = tab.content.state,
            let record = terminal.agentSession,
            !claimed.contains(tab.content.id),
            !liveSessionNames.contains(ZmxSessionID.make(surfaceID: tab.content.id.rawValue))
          else { continue }
          rows.append(
            PendingAgentResume(
              id: tab.content.id,
              worktreeID: layout.id,
              tabID: tab.id,
              repositoryName: repository,
              worktreeName: worktree.name,
              tabTitle: tab.customTitle ?? tab.title,
              agent: record.agent,
              sessionID: record.sessionID
            )
          )
        }
      }
      if !rows.isEmpty { groups.append(rows) }
    }
    // Sorting whole per-worktree groups keeps the pane / tab order inside each.
    let sorted = groups.enumerated().sorted { lhs, rhs in
      let left = lhs.element[0]
      let right = rhs.element[0]
      let byRepository = left.repositoryName.localizedStandardCompare(right.repositoryName)
      if byRepository != .orderedSame { return byRepository == .orderedAscending }
      let byWorktree = left.worktreeName.localizedStandardCompare(right.worktreeName)
      if byWorktree != .orderedSame { return byWorktree == .orderedAscending }
      return lhs.offset < rhs.offset
    }
    var pending = IdentifiedArrayOf<PendingAgentResume>()
    for row in sorted.flatMap(\.element) {
      pending.append(row)
    }
    return pending
  }
}
