import AppKit
import SwiftUI

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
