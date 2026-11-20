import ComposableArchitecture
import Foundation

// РС5: the remote window flashes the pane a pending Close Tab confirmation is about, as the main
// window does (`PaneHighlight`). Read from the alert the reducer already holds; no new state.
extension RemoteClientFeature {
  /// A pending Close Tab confirmation whose pane is on screen.
  nonisolated struct CloseFlash: Equatable, Sendable {
    let paneID: String
    let alertID: UUID
  }

  /// The tab a Close Tab confirmation (`confirmCloseTabAlert`) asks about; nil for any other alert
  /// (a failure, Close Pane, Delete Worktree).
  static func closeConfirmationTabID(_ alert: AlertState<Action.Alert>) -> String? {
    alert.buttons.lazy.compactMap { button -> String? in
      guard case .confirmCloseTab(let tabID) = button.action.action else { return nil }
      return tabID
    }
    .first
  }
}

extension RemoteClientFeature.State {
  /// The shown pane the pending Close Tab confirmation is about, with that alert's id. Nil when no
  /// such confirmation is pending or its tab is not in a pane on screen (a parked group, a pane a
  /// zoom hides): then nothing flashes and the dialog shows at once.
  var closeFlash: RemoteClientFeature.CloseFlash? {
    guard let alert, let tabID = RemoteClientFeature.closeConfirmationTabID(alert),
      let paneID = projection?.shownPaneID(holdingTab: tabID)
    else { return nil }
    return RemoteClientFeature.CloseFlash(paneID: paneID, alertID: alert.id)
  }
}

extension RemoteLayoutProjection {
  /// The shown pane of the active group (only the zoomed one when zoomed) that holds the tab,
  /// selected or not.
  func shownPaneID(holdingTab tabID: String) -> String? {
    guard let group = activeGroup else { return nil }
    let shown = group.zoomedPaneID.map { [$0] } ?? Self.paneIDs(in: group.tree)
    return shown.first { panes[$0]?.tabs.contains { $0.id == tabID } == true }
  }
}
