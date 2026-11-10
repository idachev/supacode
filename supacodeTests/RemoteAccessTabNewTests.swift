import Clocks
import ConcurrencyExtras
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

/// The `tab.new` rules that need no live app store: which worktrees refuse a
/// tab, and the bounded wait for the new tab (`RemoteHostRouter.poll`).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteAccessTabNewTests {
  @Test func onlyAKnownLiveWorktreeGetsATab() {
    #expect(RemoteTabNewRejection.check(found: true, isArchived: false, isMissing: false) == nil)
    #expect(RemoteTabNewRejection.check(found: false, isArchived: false, isMissing: false) == .unknownWorktree)
    #expect(RemoteTabNewRejection.check(found: true, isArchived: true, isMissing: false) == .archivedWorktree)
    #expect(RemoteTabNewRejection.check(found: true, isArchived: false, isMissing: true) == .missingWorktree)
    #expect(RemoteTabNewRejection.check(found: true, isArchived: true, isMissing: true) == .archivedWorktree)
  }

  // MARK: - Start size

  private static func grid(_ json: String) throws -> RemoteTabNewGrid {
    let message = try #require(RemoteJSON.decodeInbound(Data(json.utf8)))
    return RemoteTabNewGrid.resolve(cols: message.cols, rows: message.rows, fallback: RemoteHostRouter.newTabGrid)
  }

  private static let defaultCap = RemoteTabNewGrid(columns: 120, rows: 40, exact: false)

  @Test func aRequestedSizeIsDecodedAndTakenExactly() throws {
    let message = try #require(
      RemoteJSON.decodeInbound(Data(#"{"t":"tab.new","id":4,"worktreeId":"w","cols":80,"rows":24}"#.utf8)))
    #expect(message.worktreeId == "w")
    #expect(message.cols == RemoteLenientInt(80))
    #expect(message.rows == RemoteLenientInt(24))
    #expect(
      try Self.grid(#"{"t":"tab.new","id":4,"worktreeId":"w","cols":80,"rows":24}"#)
        == RemoteTabNewGrid(columns: 80, rows: 24, exact: true))
  }

  @Test func noSizeKeepsTheDefaultCap() throws {
    #expect(try Self.grid(#"{"t":"tab.new","id":4,"worktreeId":"w"}"#) == Self.defaultCap)
  }

  @Test func onlyOneOfColsAndRowsKeepsTheDefaultCap() throws {
    #expect(try Self.grid(#"{"t":"tab.new","id":4,"worktreeId":"w","cols":80}"#) == Self.defaultCap)
    #expect(try Self.grid(#"{"t":"tab.new","id":4,"worktreeId":"w","rows":24}"#) == Self.defaultCap)
  }

  @Test func aSizeThatIsNotAnIntegerKeepsTheRequestAndTheDefaultCap() throws {
    // A bad optional field must not drop the whole request.
    let message = try #require(
      RemoteJSON.decodeInbound(Data(#"{"t":"tab.new","id":4,"worktreeId":"w","cols":"80","rows":24}"#.utf8)))
    #expect(message.t == "tab.new")
    #expect(message.id == 4)
    #expect(message.worktreeId == "w")
    #expect(try Self.grid(#"{"t":"tab.new","id":4,"worktreeId":"w","cols":"80","rows":24}"#) == Self.defaultCap)
    #expect(try Self.grid(#"{"t":"tab.new","id":4,"worktreeId":"w","cols":80.5,"rows":24}"#) == Self.defaultCap)
    #expect(try Self.grid(#"{"t":"tab.new","id":4,"worktreeId":"w","cols":80,"rows":null}"#) == Self.defaultCap)
    #expect(try Self.grid(#"{"t":"tab.new","id":4,"worktreeId":"w","cols":80,"rows":true}"#) == Self.defaultCap)
    #expect(try Self.grid(#"{"t":"tab.new","id":4,"worktreeId":"w","cols":[80],"rows":24}"#) == Self.defaultCap)
  }

  @Test func aRequestedSizeIsClampedToTheHostLimits() {
    func resolve(_ cols: Int, _ rows: Int) -> RemoteTabNewGrid {
      RemoteTabNewGrid.resolve(
        cols: RemoteLenientInt(cols), rows: RemoteLenientInt(rows), fallback: RemoteHostRouter.newTabGrid)
    }
    #expect(resolve(19, 4) == RemoteTabNewGrid(columns: 20, rows: 5, exact: true))
    #expect(resolve(20, 5) == RemoteTabNewGrid(columns: 20, rows: 5, exact: true))
    #expect(resolve(500, 200) == RemoteTabNewGrid(columns: 500, rows: 200, exact: true))
    #expect(resolve(501, 201) == RemoteTabNewGrid(columns: 500, rows: 200, exact: true))
    #expect(resolve(0, -3) == RemoteTabNewGrid(columns: 20, rows: 5, exact: true))
    #expect(resolve(10_000, 10_000) == RemoteTabNewGrid(columns: 500, rows: 200, exact: true))
  }

  @Test func aLocalWorktreeTabStartsInTheWorktreeDirectory() {
    let local = Worktree(
      location: .local(
        workingDirectory: URL(filePath: "/Users/x/repo/wt", directoryHint: .isDirectory),
        repositoryRoot: URL(filePath: "/Users/x/repo", directoryHint: .isDirectory)),
      kind: .git, name: "wt", detail: "")
    #expect(RemoteSnapshotSource.newTabDirectory(for: local)?.hasPrefix("/Users/x/repo/wt") == true)
    let remote = Worktree(
      location: .remote(RemoteHost(alias: "devbox"), workingDirectory: "/home/me/wt", repositoryRoot: "/home/me"),
      kind: .git, name: "wt", detail: "")
    #expect(RemoteSnapshotSource.newTabDirectory(for: remote) == nil)
  }

  @Test func aTabAlreadyListedAnswersWithoutWaitingForTheClock() async {
    let clock = TestClock()
    let content = UUID()
    let found = await RemoteHostRouter.poll(every: .milliseconds(100), within: .seconds(10), clock: clock) {
      content
    }
    #expect(found == content)
  }

  @Test func aTabThatAppearsBeforeTheDeadlineIsReturned() async {
    let clock = TestClock()
    let content = UUID()
    let probes = LockIsolated(0)
    let wait = Task { @MainActor in
      await RemoteHostRouter.poll(every: .milliseconds(100), within: .seconds(10), clock: clock) { () -> UUID? in
        probes.withValue { $0 += 1 }
        return probes.value >= 4 ? content : nil
      }
    }
    await Task.megaYield()
    await clock.advance(by: .milliseconds(300))
    #expect(await wait.value == content)
    #expect(probes.value == 4)
  }

  @Test func aTabThatNeverAppearsGivesUpAtTheDeadline() async {
    let clock = TestClock()
    let wait = Task { @MainActor in
      await RemoteHostRouter.poll(
        every: .milliseconds(100), within: RemoteHostRouter.tabNewTimeout, clock: clock
      ) { () -> UUID? in nil }
    }
    await Task.megaYield()
    await clock.advance(by: RemoteHostRouter.tabNewTimeout)
    #expect(await wait.value == nil)
  }

  @Test func aCancelledWaitGivesUp() async {
    let clock = TestClock()
    let wait = Task { @MainActor in
      await RemoteHostRouter.poll(every: .milliseconds(100), within: .seconds(10), clock: clock) { () -> UUID? in
        nil
      }
    }
    await Task.megaYield()
    wait.cancel()
    #expect(await wait.value == nil)
  }
}
