import Foundation

/// One-shot gate for typing an agent's resume command into a restored pane.
/// Holds the `supa-*` zmx session names that were alive when the app
/// launched, captured before any restored pane could attach (an attach
/// upserts the session, and after that every session looks alive). A pane
/// whose session was already alive kept its agent, so it never resumes; a
/// dead one resumes once per process.
nonisolated struct AgentResumeGate: Equatable, Sendable {
  let liveSessionNames: Set<String>
  private(set) var claimed: Set<ContentID>

  init(liveSessionNames: Set<String>) {
    self.liveSessionNames = liveSessionNames
    self.claimed = []
  }

  /// True only for content whose zmx session was not alive at launch and that
  /// has not claimed a resume yet in this process; a true result spends the slot.
  mutating func claim(_ id: ContentID) -> Bool {
    guard !liveSessionNames.contains(ZmxSessionID.make(surfaceID: id.rawValue)) else { return false }
    return claimed.insert(id).inserted
  }
}
