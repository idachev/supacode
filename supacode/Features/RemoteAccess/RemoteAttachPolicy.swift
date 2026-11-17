import Foundation

/// Which of a connection's attachments an `attach` stops (ПТ1): with `keep`
/// the others stay, without it every other one goes; a re-attach of the same
/// content always restarts that one stream. A connection holds at most
/// `limit` attachments; one more is refused and changes nothing.
nonisolated enum RemoteAttachPolicy {
  static let limit = 16
  /// The `error.code` of a refused `attach` (`limitReached`).
  static let limitErrorCode = "attach_limit"
  static let limitErrorMessage = "too many attached terminals"

  enum Decision: Equatable {
    /// Start the stream after stopping these attachments of the same connection.
    case attach(detaching: Set<UUID>)
    case limitReached
  }

  static func decide(attached: Set<UUID>, contentID: UUID, keep: Bool) -> Decision {
    guard keep else { return .attach(detaching: attached) }
    if attached.contains(contentID) { return .attach(detaching: [contentID]) }
    guard attached.count < limit else { return .limitReached }
    return .attach(detaching: [])
  }
}
