import SwiftUI

/// File ▸ "Open Remote Mac…" (ПЗ1). The main window and the remote window publish the action; in
/// any other key window (Settings, a reference) the item is disabled.
struct RemoteClientCommands: Commands {
  /// ⌃⌘O: no default app shortcut and no default Ghostty binding uses it.
  static let shortcut = KeyboardShortcut("o", modifiers: [.command, .control])

  @FocusedValue(\.openRemoteClientAction) private var openRemoteClientAction

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Open Remote Mac…", systemImage: "desktopcomputer") {
        openRemoteClientAction?()
      }
      .keyboardShortcut(Self.shortcut)
      .help("Open a window onto another Mac's Supacode (⌃⌘O)")
      .disabled(openRemoteClientAction?.isEnabled != true)
    }
  }
}

private struct OpenRemoteClientActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var openRemoteClientAction: FocusedAction<Void>? {
    get { self[OpenRemoteClientActionKey.self] }
    set { self[OpenRemoteClientActionKey.self] = newValue }
  }
}

/// Publishes "Open Remote Mac…" for the scene it is applied to.
private struct OpenRemoteClientActionPublisher: ViewModifier {
  @Environment(\.openWindow) private var openWindow

  func body(content: Content) -> some View {
    // Captures only `openWindow`, which is stable: no token.
    content.focusedSceneAction(\.openRemoteClientAction, enabled: true) {
      openWindow(id: WindowID.remoteClient)
    }
  }
}

extension View {
  func publishesOpenRemoteClientAction() -> some View {
    modifier(OpenRemoteClientActionPublisher())
  }
}
