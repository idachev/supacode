import AppKit
import ComposableArchitecture
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

/// Edit ▸ Go to Worktree and Command Palette. Both open the main window's palette, so they are
/// disabled while a "Remote Mac" window is key (its `remoteWorktreeMenu` focused value is present):
/// otherwise they would act on the main window behind it.
struct CommandPaletteCommands: Commands {
  let store: StoreOf<AppFeature>
  @FocusedValue(\.remoteWorktreeMenu) private var remote

  var body: some Commands {
    let isRemote = remote != nil
    let overrides = store.settings.shortcutOverrides
    CommandGroup(after: .textEditing) {
      Button("Go to Worktree") {
        guard NSApp.currentEvent?.isAutoRepeatKeyDown != true else { return }
        store.send(.commandPalette(.togglePresentInMode(.worktreeSwitcher)))
      }
      .appKeyboardShortcut(AppShortcuts.worktreeSwitcher.effective(from: overrides))
      .disabled(isRemote)
      .help("Switch between worktrees, sorted by most recently used")
      Button("Command Palette") {
        guard NSApp.currentEvent?.isAutoRepeatKeyDown != true else { return }
        store.send(.commandPalette(.togglePresentInMode(.commands)))
      }
      .appKeyboardShortcut(AppShortcuts.commandPalette.effective(from: overrides))
      .disabled(isRemote)
      .help("Command Palette")
    }
  }
}
