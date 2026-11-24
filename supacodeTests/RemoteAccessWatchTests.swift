import Clocks
import ConcurrencyExtras
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

/// `watch` (ПТ3): the change classification and the per-connection record
/// (`RemoteWatch`, `RemoteWatchers`), then the router's pushes on a
/// `TestClock` (`RemoteRouterHarness`).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteAccessWatchTests {
  // MARK: - Change

  /// A one-repo, one-worktree `list` whose worktree has a tab per title.
  private static func list(
    titles: [String],
    activity: String = "idle",
    id: Int? = nil,
    layout: RemoteLayout? = nil,
    reminder: AgentInputReminder? = nil
  ) -> RemoteListMessage {
    let tabs = titles.enumerated().map { index, title in
      RemoteTab(
        id: "tab-\(index)", contentId: "content-\(index)", title: title, focused: index == 0, working: false,
        readOnly: false, agents: [RemoteAgent(agent: "claude", activity: activity)], inputReminder: reminder)
    }
    let worktree = RemoteWorktree(
      id: "/tmp/repo", name: "repo", branch: "main", status: "idle", focused: true, title: nil, working: false,
      tabs: tabs, canDeleteWorktree: false, layout: layout)
    let repository = RemoteRepository(
      id: "/tmp/repo", name: "repo", worktrees: [worktree], rowIds: ["/tmp/repo"], canCreateWorktree: true)
    return RemoteListMessage(id: id, repos: [repository])
  }

  @Test func nothingSentYetIsStructural() {
    #expect(RemoteWatch.change(from: nil, to: Self.list(titles: ["zsh"])) == .structural)
  }

  @Test func anEqualSnapshotIsNoChange() {
    #expect(RemoteWatch.change(from: Self.list(titles: ["zsh"]), to: Self.list(titles: ["zsh"])) == .none)
  }

  @Test func theRequestIDIsNoChange() {
    // A `list` reply (id 7) recorded as the last sent equals the pushed one (id null).
    #expect(RemoteWatch.change(from: Self.list(titles: ["zsh"], id: 7), to: Self.list(titles: ["zsh"])) == .none)
  }

  @Test func onlyATabTitleDiffers() {
    #expect(RemoteWatch.change(from: Self.list(titles: ["zsh"]), to: Self.list(titles: ["vim"])) == .titlesOnly)
  }

  @Test func aNewTabIsStructural() {
    #expect(
      RemoteWatch.change(from: Self.list(titles: ["zsh"]), to: Self.list(titles: ["zsh", "zsh"])) == .structural)
  }

  @Test func anAgentActivityChangeIsStructural() {
    #expect(
      RemoteWatch.change(
        from: Self.list(titles: ["zsh"], activity: "idle"), to: Self.list(titles: ["vim"], activity: "working"))
        == .structural)
    #expect(
      RemoteWatch.change(
        from: Self.list(titles: ["zsh"], activity: "idle"), to: Self.list(titles: ["zsh"], activity: "working"))
        == .structural)
  }

  @Test func aReminderChangeIsStructuralEvenIfTheAgentWasAlreadyWaiting() {
    let before = Self.list(titles: ["Codex"], activity: "awaitingInput")
    let after = Self.list(
      titles: ["Codex"], activity: "awaitingInput", reminder: AgentInputReminder(id: UUID(), agent: .claude))
    #expect(RemoteWatch.change(from: before, to: after) == .structural)
    #expect(RemoteWatch.change(from: after, to: before) == .structural)
  }

  @Test func aLayoutChangeWithTheSameTitlesIsStructural() {
    let layout = RemoteLayout(
      mode: "tabsPerSplit", activeGroupId: "main",
      groups: [RemoteLayoutGroup(id: "main", tree: .pane("pane-1"))],
      panes: [RemoteLayoutPane(id: "pane-1", tabIds: ["tab-0"], selectedTabId: "tab-0")])
    #expect(
      RemoteWatch.change(from: Self.list(titles: ["zsh"]), to: Self.list(titles: ["vim"], layout: layout))
        == .structural)
  }

  @Test func titleOnlyChangesWaitTwoSeconds() {  // РФ4
    #expect(!RemoteWatch.sends(.titlesOnly, sinceLastSend: .milliseconds(1999)))
    #expect(RemoteWatch.sends(.titlesOnly, sinceLastSend: .seconds(2)))
    #expect(RemoteWatch.sends(.structural, sinceLastSend: .zero))
    #expect(!RemoteWatch.sends(.none, sinceLastSend: .seconds(60)))
  }

  // MARK: - Watchers

  @Test func aNewWatcherGetsTheFirstTickThenOnlyChanges() {
    var watchers = RemoteWatchers()
    watchers.start("c1")
    let first = watchers.tick(Self.list(titles: ["zsh"]), elapsed: RemoteWatch.interval)
    #expect(first == ["c1"])
    let same = watchers.tick(Self.list(titles: ["zsh"]), elapsed: RemoteWatch.interval)
    #expect(same.isEmpty)
    let structural = watchers.tick(Self.list(titles: ["zsh", "zsh"]), elapsed: RemoteWatch.interval)
    #expect(structural == ["c1"])
  }

  @Test func aTitleChangeIsSentOnceTwoSecondsPassedSinceTheLastSend() {
    var watchers = RemoteWatchers()
    watchers.start("c1")
    _ = watchers.tick(Self.list(titles: ["zsh"]), elapsed: RemoteWatch.interval)
    // 7 ticks of 250 ms: 1.75 s since the last send, the title change waits.
    for _ in 0..<7 {
      let sent = watchers.tick(Self.list(titles: ["vim"]), elapsed: RemoteWatch.interval)
      #expect(sent.isEmpty)
    }
    // The 8th tick reaches 2 s and carries the latest title.
    let sent = watchers.tick(Self.list(titles: ["less"]), elapsed: RemoteWatch.interval)
    #expect(sent == ["c1"])
    #expect(watchers.lastSent(to: "c1") == Self.list(titles: ["less"]))
  }

  @Test func aStructuralChangeCarriesTheWaitingTitles() {
    var watchers = RemoteWatchers()
    watchers.start("c1")
    _ = watchers.tick(Self.list(titles: ["zsh"]), elapsed: RemoteWatch.interval)
    let waiting = watchers.tick(Self.list(titles: ["vim"]), elapsed: RemoteWatch.interval)
    #expect(waiting.isEmpty)
    let sent = watchers.tick(Self.list(titles: ["vim", "zsh"]), elapsed: RemoteWatch.interval)
    #expect(sent == ["c1"])
    #expect(watchers.lastSent(to: "c1") == Self.list(titles: ["vim", "zsh"]))
  }

  @Test func aRecordedReplyCountsAsTheLastSend() {
    var watchers = RemoteWatchers()
    watchers.start("c1")
    watchers.recordSent(Self.list(titles: ["zsh"], id: 7), to: "c1")
    let same = watchers.tick(Self.list(titles: ["zsh"]), elapsed: RemoteWatch.interval)
    #expect(same.isEmpty)
    // A connection that does not watch records nothing.
    watchers.recordSent(Self.list(titles: ["zsh"]), to: "c2")
    #expect(watchers.lastSent(to: "c2") == nil)
    #expect(watchers.connIDs == ["c1"])
  }

  @Test func aRepeatedWatchKeepsTheRecord() {
    var watchers = RemoteWatchers()
    watchers.start("c1")
    _ = watchers.tick(Self.list(titles: ["zsh"]), elapsed: RemoteWatch.interval)
    watchers.start("c1")
    let same = watchers.tick(Self.list(titles: ["zsh"]), elapsed: RemoteWatch.interval)
    #expect(same.isEmpty)
  }

  @Test func anEndedWatcherGetsNothing() {
    var watchers = RemoteWatchers()
    watchers.start("c1")
    watchers.start("c2")
    watchers.end("c1")
    let sent = watchers.tick(Self.list(titles: ["zsh"]), elapsed: RemoteWatch.interval)
    #expect(sent == ["c2"])
    watchers.end("c2")
    #expect(watchers.isEmpty)
  }

  // MARK: - Router

  private static let watchOn = #"{"t":"watch","id":5,"on":true}"#
  private static let watchOff = #"{"t":"watch","id":6,"on":false}"#

  /// Advances `clock` one watch interval at a time, yielding before and after
  /// each step so the tick task has registered its sleep, until `condition`
  /// holds or `steps` intervals passed. Returns whether it held.
  @discardableResult
  private static func advance(
    _ clock: TestClock<Duration>, steps: Int = 40, until condition: () -> Bool
  ) async -> Bool {
    for _ in 0..<steps {
      if condition() { return true }
      await Task.megaYield()
      await clock.advance(by: RemoteWatch.interval)
      await Task.megaYield()
    }
    return condition()
  }

  /// Steps `clock` through `duration` one watch interval at a time, yielding
  /// around each step, so every tick in that span runs.
  private static func run(_ clock: TestClock<Duration>, for duration: Duration) async {
    var passed = Duration.zero
    while passed < duration {
      await Task.megaYield()
      await clock.advance(by: RemoteWatch.interval)
      await Task.megaYield()
      passed += RemoteWatch.interval
    }
  }

  @Test func theWatchReplyEchoesIDAndOn() throws {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let phone = harness.openPhone("c1")
    harness.send("c1", Self.watchOn)
    let reply = try #require(phone.messages.first)
    #expect(reply["t"] as? String == "watch")
    #expect(reply["id"] as? Int == 5)
    #expect(reply["on"] as? Bool == true)
    #expect(harness.router.isWatchTicking)
    // A missing `on` means true.
    harness.send("c1", #"{"t":"watch","id":9}"#)
    let second = try #require(phone.messages.last)
    #expect(second["on"] as? Bool == true)
  }

  @Test func aWatchingConnectionGetsOneListAndThenNothingWhileNothingChanges() async throws {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let phone = harness.openPhone("c1")
    #expect(!harness.router.isWatchTicking)
    harness.send("c1", Self.watchOn)
    #expect(phone.messages.first?["t"] as? String == "watch")
    await Task.megaYield()
    // Nothing goes out before the first interval passed.
    #expect(phone.frames.value.count == 1)
    let pushed = await Self.advance(clock) { phone.frames.value.count >= 2 }
    #expect(pushed)
    let list = try #require(phone.messages.last)
    #expect(list["t"] as? String == "list")
    #expect(list["id"] is NSNull)
    await Self.run(clock, for: .seconds(5))
    #expect(phone.frames.value.count == 2)
  }

  @Test func aListReplyToAWatcherCountsAsTheLastSent() async throws {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let phone = harness.openPhone("c1")
    // A second watcher without a `list` request proves the tick ran.
    let other = harness.openPhone("c2")
    harness.send("c1", Self.watchOn)
    harness.send("c2", Self.watchOn)
    harness.send("c1", #"{"t":"list","id":7}"#)
    #expect(phone.messages(ofType: "list").count == 1)
    let ticked = await Self.advance(clock) { other.messages(ofType: "list").count == 1 }
    #expect(ticked)
    await Self.run(clock, for: .seconds(3))
    #expect(phone.messages(ofType: "list").count == 1)
    #expect(phone.messages(ofType: "list").first?["id"] as? Int == 7)
  }

  @Test func watchOffStopsThePushes() async throws {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let phone = harness.openPhone("c1")
    harness.send("c1", Self.watchOn)
    harness.send("c1", Self.watchOff)
    #expect(!harness.router.isWatchTicking)
    await Self.run(clock, for: .seconds(1))
    #expect(phone.messages.map { $0["t"] as? String } == ["watch", "watch"])
    let off = try #require(phone.messages.last)
    #expect(off["id"] as? Int == 6)
    #expect(off["on"] as? Bool == false)
  }

  @Test func aClosedConnectionStopsItsWatch() async throws {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let phone = harness.openPhone("c1")
    harness.send("c1", Self.watchOn)
    harness.router.lanClosed("c1")
    #expect(!harness.router.isWatchTicking)
    await Self.run(clock, for: .seconds(1))
    #expect(phone.frames.value.count == 1)
  }

  @Test func theTickRunsWhileAnyConnectionWatches() async throws {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    let first = harness.openPhone("c1")
    let second = harness.openPhone("c2")
    harness.send("c1", Self.watchOn)
    harness.send("c2", Self.watchOn)
    harness.router.lanClosed("c1")
    #expect(harness.router.isWatchTicking)
    let pushed = await Self.advance(clock) { second.frames.value.count >= 2 }
    #expect(pushed)
    #expect(first.frames.value.count == 1)
  }

  @Test func aRelayConnCloseEndsItsWatch() {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    // A relay phone: no LAN sink, so its frames go nowhere here.
    harness.send("r1", #"{"t":"conn.open"}"#)
    harness.send("r1", Self.watchOn)
    #expect(harness.router.isWatchTicking)
    harness.send("r1", #"{"t":"conn.close"}"#)
    #expect(!harness.router.isWatchTicking)
  }

  @Test func aLateWatchAfterTheConnectionClosedStartsNothing() {  // review F7
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    harness.send("r1", #"{"t":"conn.open"}"#)
    harness.send("r1", #"{"t":"conn.close"}"#)
    harness.send("r1", Self.watchOn)
    #expect(!harness.router.isWatchTicking)
    // Nor from a connection the router never knew.
    harness.send("r2", Self.watchOn)
    #expect(!harness.router.isWatchTicking)
  }

  @Test func aDetachOfEverythingKeepsTheWatch() {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    defer { harness.router.stop() }
    _ = harness.openPhone("c1")
    harness.send("c1", Self.watchOn)
    harness.send("c1", #"{"t":"detach"}"#)
    #expect(harness.router.isWatchTicking)
  }

  @Test func stopEndsEveryWatch() {
    let clock = TestClock()
    let harness = RemoteRouterHarness(clock: clock)
    _ = harness.openPhone("c1")
    harness.send("r1", #"{"t":"conn.open"}"#)
    harness.send("r1", Self.watchOn)
    harness.send("c1", Self.watchOn)
    harness.router.stop()
    #expect(!harness.router.isWatchTicking)
  }
}
