import SwiftUI

/// File ▸ "Open Remote Mac…" (ПЗ1). Opening the window does not depend on which window is key, and
/// the app can run with no window open at all, so the item reads `openWindow` itself and is always
/// enabled (a focused scene action would leave it grey with no window).
struct RemoteClientCommands: Commands {
  /// ⌃⌘O: no default app shortcut and no default Ghostty binding uses it.
  static let shortcut = KeyboardShortcut("o", modifiers: [.command, .control])

  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Open Remote Mac…", systemImage: "desktopcomputer") {
        openWindow(id: WindowID.remoteClient)
      }
      .keyboardShortcut(Self.shortcut)
      .help("Open a window onto another Mac's Supacode (⌃⌘O)")
    }
  }
}
