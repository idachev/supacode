import AppKit
import ComposableArchitecture
import Foundation
import SupacodeSettingsShared
import SwiftUI

nonisolated private let remoteNotifierLogger = SupaLogger("RemoteClient")

/// The "agent is waiting" system notification of the remote window (ИВ1–ИВ4): what it says, under
/// which identifier, and the deeplink its tap carries. Ids only: never a key, a relay URL or a path
/// of this Mac.
nonisolated enum RemoteClientNotifier {
  /// Where a tap leads: the worktree and the remote content of the waiting tab.
  struct Target: Equatable, Sendable {
    let worktreeID: String
    let contentID: String
  }

  private static let scheme = "supacode"
  private static let host = "remote-client"
  private static let path = "/notification"

  /// Stable per Mac and tab, so a new one replaces the old: "remote:<hostId>:<contentId>".
  static func identifier(hostID: String?, contentID: String) -> String {
    "remote:\(hostID ?? ""):\(contentID)"
  }

  /// "<Mac> — agent is waiting".
  static func title(hostName: String?) -> String {
    let name = hostName.flatMap { $0.isEmpty ? nil : $0 } ?? "Remote Mac"
    return "\(name) — agent is waiting"
  }

  /// "<worktree> · <tab title>".
  static func body(_ tab: RemoteAwaitingTab) -> String {
    "\(tab.worktreeName) · \(tab.tabTitle)"
  }

  /// Not when the tab is visible in the key remote window.
  static func shouldPost(_ tab: RemoteAwaitingTab, isKeyWindow: Bool, visibleContentIDs: [String]) -> Bool {
    !(isKeyWindow && visibleContentIDs.contains(tab.contentId))
  }

  /// `supacode://remote-client/notification?worktree=<id>&content=<id>`.
  static func url(worktreeID: String, contentID: String) -> URL? {
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.path = path
    components.queryItems = [
      URLQueryItem(name: "worktree", value: worktreeID),
      URLQueryItem(name: "content", value: contentID),
    ]
    return components.url
  }

  /// The target of a remote-client notification URL; nil for any other URL or one without both ids.
  static func target(of url: URL) -> Target? {
    guard isRemoteClientURL(url),
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
      let worktreeID = items.first(where: { $0.name == "worktree" })?.value, !worktreeID.isEmpty,
      let contentID = items.first(where: { $0.name == "content" })?.value, !contentID.isEmpty
    else { return nil }
    return Target(worktreeID: worktreeID, contentID: contentID)
  }

  /// Any `supacode://remote-client/…` URL: the remote window's, never the app's deeplinks.
  static func isRemoteClientURL(_ url: URL) -> Bool {
    url.scheme?.lowercased() == scheme && url.host()?.lowercased() == host
  }
}

/// Routes taps on remote notifications to the remote window, so they never reach `AppFeature`'s
/// deeplinks. The window root registers its store while the window is open and its `NSWindow`
/// (both weak); a tap brings that window forward, then selects the tab.
@MainActor
final class RemoteClientNotificationRouter {
  static let shared = RemoteClientNotificationRouter()

  /// Set while the remote window is open.
  weak var store: StoreOf<RemoteClientFeature>?
  weak var window: NSWindow?

  nonisolated deinit {}

  /// True when the URL is a remote-client one: handled, or dropped when the window is closed or the
  /// URL is malformed. False: not ours, the caller routes it as before.
  func open(_ url: URL) -> Bool {
    guard RemoteClientNotifier.isRemoteClientURL(url) else { return false }
    guard let target = RemoteClientNotifier.target(of: url) else {
      remoteNotifierLogger.warning("Dropped a remote notification tap: no target")
      return true
    }
    guard let store else {
      remoteNotifierLogger.info("Dropped a remote notification tap: the remote window is closed")
      return true
    }
    if let window {
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
    }
    NSApplication.shared.activate()
    store.send(.notificationOpened(worktreeID: target.worktreeID, contentID: target.contentID))
    return true
  }
}

/// Hands the remote window's `NSWindow` to the router, so a notification tap can bring it forward.
struct RemoteClientWindowAnchor: NSViewRepresentable {
  func makeNSView(context: Context) -> RemoteClientWindowAnchorView {
    RemoteClientWindowAnchorView()
  }

  func updateNSView(_ nsView: RemoteClientWindowAnchorView, context: Context) {}
}

final class RemoteClientWindowAnchorView: NSView {
  nonisolated deinit {}

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    RemoteClientNotificationRouter.shared.window = window
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
