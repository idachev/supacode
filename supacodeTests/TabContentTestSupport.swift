import AppKit

@testable import supacode

/// Renderless content exposing a real terminal chrome, so chrome writes are
/// observable in tests without spawning a surface.
@MainActor
final class ChromeTabContent: TabContent {
  let id: ContentID
  let kind: ContentKind = .terminal
  let terminalChrome = TerminalTabChrome()

  init(id: ContentID) {
    self.id = id
  }

  nonisolated deinit {}

  var chrome: (any TabChrome)? { terminalChrome }

  /// A live surface stand-in; nil reads as a hibernated terminal.
  var liveRenderer: NSView?
  var isBusy = false

  var renderer: NSView? { liveRenderer }

  func startSession(at geometry: ContentGeometry) {}

  func hibernate() {}

  func snapshot() -> ContentSnapshot {
    ContentSnapshot(id: id, state: .terminal(TerminalContentState(workingDirectory: nil)))
  }
}
