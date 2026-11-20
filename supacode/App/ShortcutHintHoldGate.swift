import Foundation

/// When the shortcut hints show (НП4). ⌘ or ⌃ held alone for `holdDelay` shows them; a key
/// pressed with it (⌃C, ⌃R, ⌘C in a terminal) hides them at once and keeps them hidden until
/// both modifiers are released, so a chord never flashes the hints. One rule for both keys.
/// Pure: `CommandKeyObserver` feeds it the events and runs the delay on its clock.
nonisolated struct ShortcutHintHoldGate: Equatable, Sendable {
  /// Upstream's old hold-to-reveal delay (removed in #381): a quick chord ends well before it.
  static let holdDelay: Duration = .milliseconds(300)

  enum Phase: Equatable, Sendable {
    /// Neither ⌘ nor ⌃ is down.
    case idle
    /// ⌘ or ⌃ is down alone; the hold that ends with `holdElapsed(generation)` shows the hints.
    case waiting(generation: Int)
    case showing
    /// A key went down with the modifier: hidden until both are released.
    case chorded
  }

  private(set) var phase: Phase = .idle
  private var lastGeneration = 0

  var isShowing: Bool { phase == .showing }

  var isWaiting: Bool {
    if case .waiting = phase { return true }
    return false
  }

  /// The ⌘ / ⌃ state changed. Returns the generation of a hold to start, nil for none.
  mutating func modifiersChanged(held: Bool) -> Int? {
    guard held else {
      phase = .idle
      return nil
    }
    // Adding ⇧ or ⌥, or ⌃ to ⌘, neither restarts the hold nor ends a chord.
    guard phase == .idle else { return nil }
    lastGeneration += 1
    phase = .waiting(generation: lastGeneration)
    return lastGeneration
  }

  /// A key went down. With ⌘ or ⌃ held that makes a chord; without, plain typing changes nothing.
  mutating func keyPressed() {
    guard phase != .idle else { return }
    phase = .chorded
  }

  /// A hold finished; one a later event replaced is stale and does nothing.
  mutating func holdElapsed(generation: Int) {
    guard phase == .waiting(generation: generation) else { return }
    phase = .showing
  }

  /// The app became active. A modifier already down came with another key (⌘⇥ into the app), so
  /// it counts as a chord.
  mutating func activated(held: Bool) {
    phase = held ? .chorded : .idle
  }
}
