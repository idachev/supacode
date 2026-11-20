import AppKit
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// Tracks whether the user is currently holding ⌘ or ⌃ so the UI can surface shortcut hints.
/// Fork (НП4): the hints show once the modifier is held alone for a moment, and a chord hides
/// them until release (`ShortcutHintHoldGate`).
@MainActor
@Observable
final class CommandKeyObserver {
  /// The hints show: ⌘ or ⌃ held alone past `ShortcutHintHoldGate.holdDelay`.
  var isPressed: Bool
  /// Slot-aligned Select Tab N chords, resolved here so no tab-bar view body observes the settings file.
  private var tabSelectionHints: [String?]
  private var monitor: Any?
  private var didBecomeActiveObserver: NSObjectProtocol?
  private var didResignActiveObserver: NSObjectProtocol?
  @ObservationIgnored private var holdGate = ShortcutHintHoldGate()
  @ObservationIgnored private var holdTask: Task<Void, Never>?
  @ObservationIgnored private let clock: any Clock<Duration>

  init(clock: any Clock<Duration> = ContinuousClock()) {
    isPressed = false
    self.clock = clock
    tabSelectionHints = Self.resolvedTabSelectionHints()
    monitor = nil
    didBecomeActiveObserver = nil
    didResignActiveObserver = nil
    configureObservers()
  }

  nonisolated deinit {}

  func tabSelectionHint(atSlot index: Int) -> String? {
    guard tabSelectionHints.indices.contains(index) else { return nil }
    return tabSelectionHints[index]
  }

  private func configureObservers() {
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
      MainActor.assumeIsolated {
        if event.type == .keyDown {
          self?.handleKeyDown()
        } else {
          self?.handleCommandKeyChange(isDown: Self.shouldShowShortcuts(for: event.modifierFlags))
        }
      }
      return event
    }
    let center = NotificationCenter.default
    didBecomeActiveObserver = center.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handleActivation(isDown: Self.shouldShowShortcuts(for: NSEvent.modifierFlags))
      }
    }
    didResignActiveObserver = center.addObserver(
      forName: NSApplication.didResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handleCommandKeyChange(isDown: false)
      }
    }
  }

  nonisolated static func shouldShowShortcuts(for modifierFlags: NSEvent.ModifierFlags) -> Bool {
    modifierFlags.contains(.command) || modifierFlags.contains(.control)
  }

  func handleCommandKeyChange(isDown: Bool) {
    // Re-resolve on the way in only: the hints must survive the release so consumers can fade them out.
    if isDown {
      let hints = Self.resolvedTabSelectionHints()
      if hints != tabSelectionHints {
        tabSelectionHints = hints
      }
    }
    // Fork (НП4): through the hold gate, not an immediate flip; consumers still fade the change.
    startHold(holdGate.modifiersChanged(held: isDown))
    applyHoldGate()
  }

  func handleKeyDown() {
    holdGate.keyPressed()
    applyHoldGate()
  }

  private func handleActivation(isDown: Bool) {
    holdGate.activated(held: isDown)
    applyHoldGate()
  }

  private func startHold(_ generation: Int?) {
    guard let generation else { return }
    holdTask?.cancel()
    holdTask = Task { [weak self, clock] in
      do { try await clock.sleep(for: ShortcutHintHoldGate.holdDelay) } catch { return }
      self?.holdGate.holdElapsed(generation: generation)
      self?.applyHoldGate()
    }
  }

  private func applyHoldGate() {
    if !holdGate.isWaiting {
      holdTask?.cancel()
      holdTask = nil
    }
    // keyDown arrives on every keystroke: write only a change, so views see no needless invalidation.
    if isPressed != holdGate.isShowing {
      isPressed = holdGate.isShowing
    }
  }

  private static func resolvedTabSelectionHints() -> [String?] {
    @Shared(.settingsFile) var settingsFile
    return AppShortcuts.tabSelectionShortcutDisplays(overrides: settingsFile.global.shortcutOverrides)
  }
}
