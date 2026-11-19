import AppKit
import ComposableArchitecture
import SwiftUI

/// The selected worktree's terminals as the Mac lays them out (ОБ2): the active group's split tree,
/// each pane a tab strip above its selected tab's live surface; in `splitPerTab` the group strip on
/// top. A zoomed group draws only its zoomed pane. Dividers do not drag (ПС6). Only the session's
/// own `ContentRuntime` is used; the session makes the contents (the attached set), this view only
/// hosts them. The parent sizes it.
struct RemoteLayoutView: View {
  let store: StoreOf<RemoteClientFeature>
  let session: RemoteClientSession
  let ghostty: GhosttyRuntime
  let macName: String

  // Reading it re-runs the body on a Light / Dark flip, so the dimming colour follows.
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let _ = colorScheme
    if let projection = store.projection, let worktree = store.selectedWorktree,
      let group = projection.groups.first(where: { $0.id == projection.activeGroupID })
    {
      let context = RemoteLayoutContext(
        worktreeID: worktree.id,
        panes: projection.panes,
        focusedPaneID: group.zoomedPaneID ?? group.focusedPaneID,
        zoomedPaneID: group.zoomedPaneID,
        isSplit: RemoteLayoutProjection.paneIDs(in: group.tree).count > 1,
        canEditPanes: worktree.layout != nil,
        busyRequests: store.busyRequests,
        dividerColor: ghostty.splitDividerColor() ?? Color(nsColor: .separatorColor),
        unfocusedFill: ghostty.unfocusedSplitFill(),
        unfocusedOpacity: ghostty.unfocusedSplitOverlayOpacity(),
        macName: macName
      )
      let focusedContentID = context.focusedPaneID
        .flatMap { projection.panes[$0] }
        .flatMap { pane in pane.tabs.first { $0.id == pane.selectedTabID } }?.contentId
      VStack(spacing: 0) {
        if projection.mode == "splitPerTab" {
          RemoteGroupStripView(
            groups: projection.groups,
            activeGroupID: projection.activeGroupID,
            isNewTabBusy: context.busyRequests.contains(
              RemoteClientFeature.RequestKey.newTab(worktreeID: worktree.id, paneID: nil)),
            store: store
          )
        }
        RemoteNodeView(
          node: group.zoomedPaneID.map(RemoteClientLayoutNode.pane) ?? group.tree,
          context: context, store: store, session: session)
      }
      // The keyboard follows the laptop's focused pane: on a worktree, group, pane or tab change,
      // and once its content is attached.
      .task(
        id: RemoteFocusKey(
          worktreeID: worktree.id, contentID: focusedContentID,
          isAttached: focusedContentID.flatMap(session.attachedContent) != nil)
      ) {
        guard let focusedContentID,
          let surface = session.attachedContent(focusedContentID)?.renderer as? GhosttySurfaceView,
          Self.shouldTakeFocus(surface)
        else { return }
        surface.requestFocus()
      }
    } else {
      ContentUnavailableView("No terminal", systemImage: "terminal")
    }
  }

  /// Not while the surface already has the keyboard, nor while the user types into a field (the
  /// sidebar filter, a sheet) or moves through the sidebar list, as the local layout does: arrow
  /// keys there must not end up in the Mac's shell.
  private static func shouldTakeFocus(_ surface: GhosttySurfaceView) -> Bool {
    guard let responder = surface.window?.firstResponder else { return true }
    return responder !== surface && !(responder is NSText) && !(responder is NSTableView)
      && !(responder is NSOutlineView)
  }
}

private struct RemoteFocusKey: Hashable {
  let worktreeID: String
  let contentID: String?
  let isAttached: Bool
}

/// The values every pane draws with, constant across the tree.
private struct RemoteLayoutContext {
  let worktreeID: String
  let panes: [String: RemoteLayoutProjection.PaneView]
  /// The active group's focused pane (its zoomed pane when zoomed).
  let focusedPaneID: String?
  let zoomedPaneID: String?
  /// The active group's tree has more than one pane.
  let isSplit: Bool
  let canEditPanes: Bool
  let busyRequests: Set<String>
  let dividerColor: Color
  let unfocusedFill: Color?
  let unfocusedOpacity: Double
  let macName: String

  /// Only a view of several panes dims; a zoomed or single pane is always the working one.
  func isDimmed(_ paneID: String) -> Bool {
    zoomedPaneID == nil && isSplit && focusedPaneID != paneID
  }

  func chrome(of paneID: String) -> RemotePaneChrome {
    typealias Key = RemoteClientFeature.RequestKey
    let tabIDs = panes[paneID]?.tabs.map(\.id) ?? []
    return RemotePaneChrome(
      isFocused: focusedPaneID == paneID,
      isZoomed: zoomedPaneID == paneID,
      canZoom: isSplit,
      canEditPanes: canEditPanes,
      isNewTabBusy: busyRequests.contains(Key.newTab(worktreeID: worktreeID, paneID: canEditPanes ? paneID : nil)),
      isSplitBusy: busyRequests.contains(Key.make("pane.split", paneID)),
      isCloseBusy: busyRequests.contains(Key.make("pane.close", paneID)),
      closingTabIDs: Set(tabIDs.filter { busyRequests.contains(Key.make("tab.close", $0)) })
    )
  }
}

/// One node of the tree: a split draws both sides with `SplitView`, a leaf its pane.
private struct RemoteNodeView: View {
  let node: RemoteClientLayoutNode
  let context: RemoteLayoutContext
  let store: StoreOf<RemoteClientFeature>
  let session: RemoteClientSession

  var body: some View {
    switch node {
    case .pane(let paneID):
      // The pane's own id: a split or close elsewhere leaves this leaf, and its surface, in place.
      RemotePaneLeafView(paneID: paneID, context: context, store: store, session: session)
        .id(paneID)
    case .split(let direction, let ratio, let left, let right):
      SplitView(
        SplitDirection(rawValue: direction) ?? .horizontal,
        ratio: ratio,
        dividerColor: context.dividerColor,
        left: { RemoteNodeView(node: left, context: context, store: store, session: session) },
        right: { RemoteNodeView(node: right, context: context, store: store, session: session) },
        // The Mac owns the split ratios: dragging a divider is not offered (ПС6).
        onResize: { _ in },
        onEqualize: {}
      )
    }
  }
}

/// A pane: its strip and its selected tab's terminal.
private struct RemotePaneLeafView: View {
  let paneID: String
  let context: RemoteLayoutContext
  let store: StoreOf<RemoteClientFeature>
  let session: RemoteClientSession

  var body: some View {
    if let pane = context.panes[paneID] {
      VStack(spacing: 0) {
        RemoteTabStripView(pane: pane, chrome: context.chrome(of: paneID), store: store)
        RemotePaneContentView(
          tab: pane.tabs.first { $0.id == pane.selectedTabID },
          session: session,
          macName: context.macName,
          dim: context.isDimmed(paneID)
            ? context.unfocusedFill.map { (fill: $0, opacity: context.unfocusedOpacity) } : nil
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      // The projection keeps tree and panes in step; this only shows if that slips.
      ContentUnavailableView("This pane is unavailable", systemImage: "rectangle.dashed")
    }
  }
}

/// The selected tab's live surface, or why there is none.
private struct RemotePaneContentView: View {
  let tab: RemoteClientTab?
  let session: RemoteClientSession
  let macName: String
  /// The unfocused-split fill and its opacity, when this pane is dimmed.
  let dim: (fill: Color, opacity: Double)?

  var body: some View {
    if let tab, !tab.contentId.isEmpty {
      if let content = session.attachedContent(tab.contentId) {
        if case .ended(let reason) = content.phase {
          ContentUnavailableView(
            "This terminal ended on \(macName)", systemImage: "terminal", description: Text(reason))
        } else if content.sessionFailedToStart {
          ContentUnavailableView("The terminal could not start", systemImage: "exclamationmark.triangle")
        } else {
          ContentHostView(contentID: content.id, runtime: session.runtime, epoch: UInt64(clamping: session.epoch))
            .overlay {
              if let dim, dim.opacity > 0 {
                dim.fill
                  .opacity(dim.opacity)
                  .allowsHitTesting(false)
              }
            }
        }
      } else {
        ProgressView()
      }
    } else {
      ContentUnavailableView("No terminal", systemImage: "terminal")
    }
  }
}
