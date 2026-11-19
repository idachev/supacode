import AppKit
import SupacodeSettingsShared
import SwiftUI
import Testing

@testable import supacode

/// ⌘W only ever closes the focused tab or pane, never a window (owner rule R32).
@MainActor
struct WindowCommandsTests {
  // MARK: - The hosting app's real main menu.

  /// Every main-menu item bound to `key` with exactly `modifiers`, hidden ones included.
  private static func mainMenuItems(key: String, modifiers: NSEvent.ModifierFlags) -> [NSMenuItem] {
    func walk(_ menu: NSMenu) -> [NSMenuItem] {
      menu.items.flatMap { item -> [NSMenuItem] in
        var found = item.submenu.map(walk) ?? []
        let mask = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
        if item.keyEquivalent == key, mask == modifiers { found.append(item) }
        return found
      }
    }
    return NSApp.mainMenu.map(walk) ?? []
  }

  @Test func plainCommandWBelongsOnlyToTheCloseTabItem() throws {
    // A `WindowGroup` scene brings its own File ▸ Close (⌘W, `performClose:`), which
    // replaced the app's Close Tab group and closed the window on every layout.
    let items = Self.mainMenuItems(key: "w", modifiers: [.command])
    let item = try #require(items.count == 1 ? items.first : nil, "⌘W items: \(items.map(\.title))")
    #expect(["Close Tab", "Close Terminal"].contains(item.title))
    #expect(item.action != #selector(NSWindow.performClose(_:)))
  }

  @Test func noMenuItemClosesAWindowOnCommandW() {
    let closers = Self.mainMenuItems(key: "w", modifiers: [.command])
      .filter { $0.action == #selector(NSWindow.performClose(_:)) }
    #expect(closers.isEmpty)
  }

  @Test func closeWindowHoldsCommandShiftW() {
    let items = Self.mainMenuItems(key: "w", modifiers: [.command, .shift])
    #expect(items.map(\.title) == ["Close Window"])
  }
}

/// Close Tab's action: the focused tab, a pane window's tab, or nothing; never the window.
@MainActor
struct WindowCommandsCloseTabTests {
  private final class Counter {
    var count = 0
    nonisolated deinit {}
  }

  private static func paneWindow(closing counter: Counter?) -> PaneWindow {
    let window = PaneWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: true
    )
    window.isReleasedWhenClosed = false
    if let counter { window.closeSelectedTab = { counter.count += 1 } }
    return window
  }

  @Test func enabledCloseTabActionClosesTheFocusedTab() {
    let focused = Counter()
    let paneTab = Counter()
    let action = FocusedAction<Void>(isEnabled: true) { focused.count += 1 }

    let target = WindowCommands.performCloseTab(action, keyWindow: Self.paneWindow(closing: paneTab))

    #expect(target == .focusedTab)
    #expect(focused.count == 1)
    #expect(paneTab.count == 0)
  }

  @Test func paneWindowClosesItsSelectedTabWithoutAnEnabledAction() {
    let focused = Counter()
    let paneTab = Counter()
    let action = FocusedAction<Void>(isEnabled: false) { focused.count += 1 }

    let target = WindowCommands.performCloseTab(action, keyWindow: Self.paneWindow(closing: paneTab))

    #expect(target == .paneWindowTab)
    #expect(focused.count == 0)
    #expect(paneTab.count == 1)
  }

  @Test func nothingToCloseLeavesTheWindowOpen() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: true
    )
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    defer { window.orderOut(nil) }

    #expect(WindowCommands.performCloseTab(nil, keyWindow: window) == .nothing)
    #expect(WindowCommands.performCloseTab(nil, keyWindow: nil) == .nothing)
    #expect(WindowCommands.performCloseTab(nil, keyWindow: Self.paneWindow(closing: nil)) == .nothing)
    #expect(window.isVisible)
  }

  @Test func closeWindowShortcutIsCommandShiftWAndNeverCloseTabs() {
    #expect(WindowCommands.closeWindowShortcut == KeyboardShortcut("w", modifiers: [.command, .shift]))
    let closeTab = AppShortcuts.closeTab.keyboardShortcut
    #expect(closeTab == KeyboardShortcut("w", modifiers: .command))
    #expect(WindowCommands.closeWindowShortcut != closeTab)
  }
}
