import Foundation

/// Which remote terminals stay attached (РЗ5): the visible ones, plus the ones hidden for less
/// than `linger`, at most `limit` in all. The limit counts visible contents too, and a visible
/// content is never detached, so more than `limit` visible contents stay attached.
nonisolated struct RemoteAttachedSet: Sendable {
  static let linger: Duration = .seconds(30)
  static let limit = 16

  nonisolated struct Step: Equatable, Sendable {
    var attach: [String]
    var detach: [String]
  }

  private var attached: Set<String> = []
  /// Hidden attached contents: the instant an update first saw each one hidden.
  private var hiddenSince: [String: ContinuousClock.Instant] = [:]

  /// `visible` in the window now, at `now`. Attaches new ones, in the order of `visible`; detaches
  /// (sorted) those hidden for `linger` or longer, and the least recently visible ones beyond
  /// `limit`. A visible content is never detached.
  mutating func update(visible: [String], now: ContinuousClock.Instant) -> Step {
    var attach: [String] = []
    let visibleSet = Set(visible)
    for id in visible where attached.insert(id).inserted { attach.append(id) }
    for id in visibleSet { hiddenSince[id] = nil }
    for id in attached where !visibleSet.contains(id) && hiddenSince[id] == nil { hiddenSince[id] = now }

    var detach = hiddenSince.filter { $0.value + Self.linger <= now }.map(\.key)
    var overflow = attached.count - detach.count - Self.limit
    if overflow > 0 {
      let expiring = Set(detach)
      let oldestFirst =
        hiddenSince
        .filter { !expiring.contains($0.key) }
        .sorted { ($0.value, $0.key) < ($1.value, $1.key) }
      for (id, _) in oldestFirst where overflow > 0 {
        detach.append(id)
        overflow -= 1
      }
    }
    for id in detach {
      attached.remove(id)
      hiddenSince[id] = nil
    }
    return Step(attach: attach, detach: detach.sorted())
  }

  /// The instant the next hidden content's linger ends, to schedule the next `update`.
  var nextExpiry: ContinuousClock.Instant? {
    hiddenSince.values.min().map { $0 + Self.linger }
  }
}
