import Foundation

/// The held sizes of `resize` with `hold` (`docs/remote-access-protocol.md`,
/// "resize" → `hold`), per terminal: one owner, the connection that asked last.
/// The owner's `detach` ends a hold at once; a lost owner leaves it without one
/// for `grace`, so a short drop or a LAN ⇄ relay switch does not reflow the
/// terminal twice. The router pins and unpins the grid; this only keeps owners.
nonisolated struct RemoteGridHolds {
  /// How long a hold stays without an owner after its connection or stream ended.
  static let grace: Duration = .seconds(30)

  nonisolated struct Hold: Equatable, Sendable {
    /// The connection that holds the size; nil while the hold waits out its `grace`.
    var owner: String?
    let columns: Int
    let rows: Int
  }

  private(set) var byContent: [UUID: Hold] = [:]

  /// A `resize` with `hold:true`: this connection owns the hold now.
  mutating func take(contentID: UUID, connID: String, columns: Int, rows: Int) {
    byContent[contentID] = Hold(owner: connID, columns: columns, rows: rows)
  }

  /// A `resize` without `hold`, a failed held resize, or the terminal ending. True when a hold ended.
  mutating func drop(contentID: UUID) -> Bool {
    byContent.removeValue(forKey: contentID) != nil
  }

  /// The owner sent `detach` (or attached elsewhere without `keep`). True when the hold ended.
  mutating func ownerDetached(contentID: UUID, connID: String) -> Bool {
    guard byContent[contentID]?.owner == connID else { return false }
    byContent[contentID] = nil
    return true
  }

  /// The owner's connection closed (`contentID` nil) or its stream of
  /// `contentID` failed: the hold stays, without an owner.
  /// Returns the contents whose 30 s start now, in a stable order.
  mutating func ownerLost(connID: String, contentID: UUID?) -> [UUID] {
    let lost = byContent.compactMap { id, hold -> UUID? in
      guard hold.owner == connID, contentID == nil || contentID == id else { return nil }
      return id
    }
    .sorted { $0.uuidString < $1.uuidString }
    for id in lost { byContent[id]?.owner = nil }
    return lost
  }

  /// Whether a held `resize` from `connID` may (still) pin `columns` × `rows`:
  /// the current hold is the one it took, owned by it or lost by it and in its
  /// grace. False once that hold ended or moved to a newer request.
  func allowsPin(contentID: UUID, connID: String, columns: Int, rows: Int) -> Bool {
    guard let hold = byContent[contentID], hold.columns == columns, hold.rows == rows else { return false }
    return hold.owner == connID || hold.owner == nil
  }

  /// The 30 s passed. True when the hold is still without an owner and so ends.
  mutating func graceExpired(contentID: UUID) -> Bool {
    guard let hold = byContent[contentID], hold.owner == nil else { return false }
    byContent[contentID] = nil
    return true
  }
}
