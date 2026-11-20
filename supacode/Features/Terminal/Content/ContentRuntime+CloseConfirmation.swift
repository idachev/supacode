import Foundation

extension ContentRuntime {
  /// Whether closing this content now would interrupt real work: live and busy, or a terminal with
  /// no live renderer, whose zmx session may still host a process nothing can ask about. The one
  /// rule behind the Mac's busy-gated close confirmation and the remote list's `busy` flag, so a
  /// remote client asks before Close Tab exactly when the Mac would.
  func closeWouldInterrupt(_ snapshot: ContentSnapshot?) -> Bool {
    guard let snapshot else { return false }
    guard let content = content(for: snapshot.id) else {
      return snapshot.kind == .terminal
    }
    if content.isBusy { return true }
    return content.kind == .terminal && content.renderer == nil
  }
}
