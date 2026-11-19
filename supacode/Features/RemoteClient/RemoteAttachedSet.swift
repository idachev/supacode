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

/// Runs `RemoteAttachedSet` on a clock (РЗ5): every `setVisible` updates the set, applies the
/// step's `detach` list before its `attach` list (so the wire never holds more than `limit`), and
/// schedules the next update at `nextExpiry`. The session wires `onAttach` / `onDetach` to making
/// and tearing down its contents.
@MainActor
final class RemoteAttachedSetDriver {
  var onAttach: (String) -> Void = { _ in }
  var onDetach: (String) -> Void = { _ in }

  private let clock: any Clock<Duration>
  /// Time on `clock` since the driver was made, added to `origin`: the set counts in
  /// `ContinuousClock.Instant`, the clock may be a `TestClock`.
  private let elapsed: () -> Duration
  private let origin = ContinuousClock.now
  private var set = RemoteAttachedSet()
  private var visible: [String] = []
  private var timer: Task<Void, Never>?
  /// Which schedule the running timer belongs to; an older timer that wakes late does nothing.
  private var generation = 0

  init(clock: any Clock<Duration>) {
    self.clock = clock
    elapsed = Self.elapsedReader(clock)
  }

  nonisolated deinit {}

  /// The contents the window shows now.
  func setVisible(_ contentIDs: [String]) {
    visible = contentIDs
    update()
  }

  /// Forgets every content without `onDetach` (the caller tore them down) and stops the timer.
  func reset() {
    set = RemoteAttachedSet()
    visible = []
    cancelTimer()
  }

  private func update() {
    let now = origin + elapsed()
    let step = set.update(visible: visible, now: now)
    for id in step.detach { onDetach(id) }
    for id in step.attach { onAttach(id) }
    schedule(after: set.nextExpiry.map { now.duration(to: $0) })
  }

  private func schedule(after delay: Duration?) {
    cancelTimer()
    guard let delay else { return }
    let generation = generation
    let clock = clock
    timer = Task { [weak self] in
      do { try await clock.sleep(for: max(delay, .zero)) } catch { return }
      // A sleep that already returned ignores `cancel()`; a newer schedule owns the handle.
      guard !Task.isCancelled, let self, self.generation == generation else { return }
      self.timer = nil
      self.update()
    }
  }

  private func cancelTimer() {
    timer?.cancel()
    timer = nil
    generation &+= 1
  }

  private static func elapsedReader<C: Clock>(_ clock: C) -> () -> Duration where C.Duration == Duration {
    let start = clock.now
    return { start.duration(to: clock.now) }
  }
}
