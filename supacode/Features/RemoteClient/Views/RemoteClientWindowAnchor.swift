import AppKit
import SwiftUI

/// Hands its remote window's `NSWindow` to the window's model, so a notification tap or a second
/// opening of the same Mac can bring that window forward.
struct RemoteClientWindowAnchor: NSViewRepresentable {
  let onWindow: (NSWindow) -> Void

  func makeNSView(context: Context) -> RemoteClientWindowAnchorView {
    let view = RemoteClientWindowAnchorView()
    view.onWindow = onWindow
    return view
  }

  func updateNSView(_ nsView: RemoteClientWindowAnchorView, context: Context) {
    nsView.onWindow = onWindow
  }
}

final class RemoteClientWindowAnchorView: NSView {
  var onWindow: ((NSWindow) -> Void)?

  nonisolated deinit {}

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    onWindow?(window)
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
