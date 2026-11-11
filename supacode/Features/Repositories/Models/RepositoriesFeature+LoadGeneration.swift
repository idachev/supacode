import Foundation

extension RepositoriesFeature {
  /// Git loads under `CancelID.load`: `started` counts the loads begun,
  /// `completed` is the highest generation whose result landed. A remote
  /// `worktrees.refresh` waits for `completed` to pass the `started` it read,
  /// so it answers only after a load that began after the request.
  ///
  /// Left out of `State` equality on purpose (`==` is always true): it is a
  /// bookkeeping counter nothing renders, and every exhaustive test that
  /// passes through a load would otherwise have to spell it out. Tests that
  /// care read `started` / `completed` directly.
  struct LoadGeneration: Equatable {
    var started = 0
    var completed = 0

    /// Starts one more load and returns its generation.
    mutating func begin() -> Int {
      started += 1
      return started
    }

    /// A load of `generation` landed; nil (a result sent without a git load) changes nothing.
    mutating func finish(_ generation: Int?) {
      guard let generation else { return }
      completed = max(completed, generation)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { true }
  }
}
