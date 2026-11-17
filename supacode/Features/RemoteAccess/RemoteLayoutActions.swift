import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

nonisolated private let layoutActionsLogger = SupaLogger("RemoteAccess")

/// Why a layout action (`tab.close`, `pane.split`, `pane.close`) was refused;
/// `code` and `message` are what the phone is told (the protocol's error tables).
nonisolated enum RemoteLayoutActionRejection: Error, Equatable, Sendable {
  /// `tab.close` without a `tabId`.
  case missingTab
  /// A `tabId` that is malformed or names no tab of any worktree.
  case unknownTab
  /// `pane.close` without a `paneId`.
  case missingPane
  /// `pane.split` without a `paneId`.
  case missingSplitPane
  /// A `paneId` that is malformed or names no pane of any worktree.
  case unknownPane
  /// A `pane.split` `direction` that is missing, not a string, or neither axis.
  case badDirection
  /// The tab is still in the layout right after the close.
  case tabStillThere
  /// The pane is still in the layout right after the close.
  case paneStillThere
  /// The new pane has no tab within the wait.
  case splitDidNotStart

  var code: String {
    switch self {
    case .missingTab, .unknownTab: "tab_invalid"
    case .tabStillThere: "tab_failed"
    case .missingPane, .missingSplitPane, .unknownPane, .badDirection: "pane_invalid"
    case .paneStillThere, .splitDidNotStart: "pane_failed"
    }
  }

  var message: String {
    switch self {
    case .missingTab: "tab.close needs a tabId"
    case .unknownTab: "no such tab"
    case .missingPane: "pane.close needs a paneId"
    case .missingSplitPane: "pane.split needs a paneId"
    case .unknownPane: "no such pane"
    case .badDirection: "direction must be horizontal or vertical"
    case .tabStillThere: "the tab is still open on the Mac"
    case .paneStillThere: "the pane is still open on the Mac"
    case .splitDidNotStart: "the new pane did not start on the Mac"
    }
  }
}

/// The pure rules of the layout actions: the split direction, which worktree
/// holds a tab or pane, and which pane a `tab.new` `paneId` anchors.
nonisolated enum RemoteLayoutActions {
  /// "horizontal" / "vertical" → SplitDirection; anything else nil (the CLI's
  /// short forms "h" / "v" are not on the wire).
  static func direction(_ raw: RemoteLenientString?) -> SplitDirection? {
    switch raw?.value {
    case "horizontal": .horizontal
    case "vertical": .vertical
    default: nil
    }
  }

  /// The worktree whose layout holds this tab, parked split-per-tab groups included.
  static func locate(tab: UUID, in layouts: [(worktreeID: String, layout: PaneLayout)]) -> String? {
    layouts.first { $0.layout.pane(containingTab: TabID(rawValue: tab)) != nil }?.worktreeID
  }

  /// The worktree whose layout holds this pane (a pane id only, not a tab or
  /// content token), parked split-per-tab groups included.
  static func locate(pane: UUID, in layouts: [(worktreeID: String, layout: PaneLayout)]) -> String? {
    layouts.first { $0.layout.panes[id: PaneID(rawValue: pane)] != nil }?.worktreeID
  }

  /// The pane a `tab.new` opens its tab in: the `paneId` when it names a pane
  /// of this worktree's layout in tabs per split; otherwise nil, the Mac's own
  /// "new tab" choice (logged when a `paneId` was sent but not used).
  static func newTabAnchor(paneID raw: String?, layout: PaneLayout?, mode: TerminalLayoutMode) -> UUID? {
    guard let raw else { return nil }
    guard let paneID = UUID(uuidString: raw), let layout, layout.panes[id: PaneID(rawValue: paneID)] != nil else {
      layoutActionsLogger.info("tab.new: paneId \(raw) is no pane of the worktree; ignored")
      return nil
    }
    guard mode == .tabsPerSplit else {
      layoutActionsLogger.info("tab.new: paneId ignored in split per tab")
      return nil
    }
    return paneID
  }
}
