import Sharing
import SupacodeSettingsShared
import SwiftUI

struct WindowCommands: Commands {
  /// ⇧⌘W. The app binds nothing else to it; Ghostty's default `close_window` on the same chord
  /// is inert in Supacode, so a terminal forwards the chord here.
  static let closeWindowShortcut = KeyboardShortcut("w", modifiers: [.command, .shift])

  @Shared(.settingsFile) private var settingsFile
  @FocusedValue(\.closeTabAction) private var closeTabAction
  @FocusedValue(\.terminateAllTerminalSessionsAction) private var terminateAllTerminalSessionsAction

  var body: some Commands {
    // ⌘W only ever closes the focused tab or pane, never a window (R32). Close Tab is
    // non-customizable and always holds ⌘W, so the chord never moves to Close Window.
    let closeTab = AppShortcuts.closeTab.effective(from: settingsFile.global.shortcutOverrides)
    // In Splits in Each Tab ⌘W closes the focused split, not the whole tab.
    // The menu bar has no layout scope, so it reads the setting (ДР9).
    let closeTabTitle = settingsFile.global.terminalLayoutMode == .splitPerTab ? "Close Terminal" : "Close Tab"
    CommandGroup(replacing: .saveItem) {
      Button(closeTabTitle, systemImage: "xmark") {
        Self.performCloseTab(closeTabAction, keyWindow: NSApp.keyWindow)
      }
      // Always enabled: with nothing to close ⌘W does nothing, rather than reaching another item.
      .appKeyboardShortcut(closeTab)

      Button("Terminate All Terminal Sessions…") {
        terminateAllTerminalSessionsAction?()
      }
      .disabled(terminateAllTerminalSessionsAction?.isEnabled != true)

      Button("Close Window") {
        // A pane window's Close Window (click or ⇧⌘W) closes its selected tab,
        // never the pane window itself.
        if let paneWindow = NSApp.keyWindow as? PaneWindow, let closeTab = paneWindow.closeSelectedTab {
          closeTab()
          return
        }
        NSApplication.shared.keyWindow?.performClose(nil)
      }
      .keyboardShortcut(Self.closeWindowShortcut)
    }
  }

  /// What Close Tab (⌘W) closed.
  enum CloseTabTarget: Equatable {
    /// The focused tab or pane, through the key window's published `closeTabAction`, which
    /// keeps its confirmation for a working tab.
    case focusedTab
    /// A pane window's selected tab, when no enabled `closeTabAction` reached the menu.
    case paneWindowTab
    case nothing
  }

  /// Closes the focused tab or pane and never a window (R32).
  @discardableResult
  static func performCloseTab(_ closeTabAction: FocusedAction<Void>?, keyWindow: NSWindow?) -> CloseTabTarget {
    if let closeTabAction, closeTabAction.isEnabled {
      closeTabAction()
      return .focusedTab
    }
    if let paneWindow = keyWindow as? PaneWindow, let closeSelectedTab = paneWindow.closeSelectedTab {
      closeSelectedTab()
      return .paneWindowTab
    }
    return .nothing
  }
}

private struct TerminateAllTerminalSessionsActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  /// Wired as a scene action so the menu enable state tracks app-wide surface
  /// presence, not the currently-selected worktree.
  var terminateAllTerminalSessionsAction: FocusedAction<Void>? {
    get { self[TerminateAllTerminalSessionsActionKey.self] }
    set { self[TerminateAllTerminalSessionsActionKey.self] = newValue }
  }
}
