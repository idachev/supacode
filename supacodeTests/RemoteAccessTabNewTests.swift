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
