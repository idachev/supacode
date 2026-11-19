import Sharing
import SwiftUI

/// File ▸ "Open Remote Mac…" (ПЗ1, R29). Opening a window does not depend on which window is key,
/// and the app can run with no window open at all, so the item reads `openWindow` itself and is
/// always enabled (a focused scene action would leave it grey with no window). With no remote
/// window open it opens the Mac picked last; with one open, a new window with the picker. A Mac
/// already shown is brought forward, never opened twice.
struct RemoteClientCommands: Commands {
  /// ⌃⌘O: no default app shortcut and no default Ghostty binding uses it.
  static let shortcut = KeyboardShortcut("o", modifiers: [.command, .control])

  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Open Remote Mac…", systemImage: "desktopcomputer") {
        @Shared(.appStorage(RemoteClientFeature.selectedHostKey)) var saved: String?
        let windows = RemoteClientWindowRegistry.shared
        windows.openWindow = { [openWindow] in openWindow(id: WindowID.remoteClient, value: $0) }
        windows.openRemoteMac(saved: saved)
      }
      .keyboardShortcut(Self.shortcut)
      .help("Open a window onto another Mac's Supacode (⌃⌘O)")
    }
  }
}

/// Hands SwiftUI's `openWindow` to the remote window registry from the main window's scene, so a
/// notification tap can open a remote window when none is open. Never cleared: the action still
/// opens windows after the main window closed.
struct RemoteClientWindowOpenerInstaller: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .onAppear {
        RemoteClientWindowRegistry.shared.openWindow = { [openWindow] in
          openWindow(id: WindowID.remoteClient, value: $0)
        }
      }
  }
}

/// Select Tab 1–9 (1-based, clamped like Ghostty's `goto_tab`), Select Previous / Next Tab.
nonisolated enum RemoteTabSelection: Hashable, Sendable {
  case index(Int)
  case previous
  case next
}

private struct RemoteTabSelectionActionKey: FocusedValueKey {
  typealias Value = FocusedAction<RemoteTabSelection>
}

extension FocusedValues {
  /// The remote window's Select Tab items. The app's Select Tab menu sends to the main window's
  /// store; while the remote window is key it publishes this and the menu calls it instead.
  var remoteTabSelectionAction: FocusedAction<RemoteTabSelection>? {
    get { self[RemoteTabSelectionActionKey.self] }
    set { self[RemoteTabSelectionActionKey.self] = newValue }
  }
}

/// The Worktrees menu items the remote window serves (R20). `selectWorktree` takes the 0-based
/// hotkey slot of Select Worktree N.
nonisolated enum RemoteWorktreeCommand: Hashable, Sendable {
  case newWorktree
  case refreshWorktrees
  case selectWorktree(slot: Int)
  case selectNextWorktree
  case selectPreviousWorktree
}

/// What the remote window offers the Worktrees menu while it is key. Its presence alone disables
/// every other store-bound Worktrees item, so nothing local fires from the remote window.
struct RemoteWorktreeMenu: Equatable {
  /// The selected worktree's repository allows New Worktree on the Mac.
  let canCreateWorktree: Bool
  let canRefreshWorktrees: Bool
  let perform: FocusedAction<RemoteWorktreeCommand>
}

private struct RemoteWorktreeMenuKey: FocusedValueKey {
  typealias Value = RemoteWorktreeMenu
}

extension FocusedValues {
  /// Published by the remote window while it is key (R20); `WorktreeCommands` reads it.
  var remoteWorktreeMenu: RemoteWorktreeMenu? {
    get { self[RemoteWorktreeMenuKey.self] }
    set { self[RemoteWorktreeMenuKey.self] = newValue }
  }
}
