import Foundation
import Testing

@testable import supacode

struct RemoteClientChoiceTests {
  static func host(_ id: String, online: Bool) -> RemoteClientHostInfo { .init(id: id, name: id, online: online) }

  // MARK: Host choice

  @Test func anOldRelayNeedsNoChoice() {
    #expect(RemoteHostChoice.decide(saved: nil, hosts: nil, ownHostID: "me") == .none)
    #expect(RemoteHostChoice.decide(saved: "office", hosts: nil, ownHostID: "me") == .none)
  }

  @Test func aSavedHostInTheListStays() {
    #expect(RemoteHostChoice.decide(saved: "a", hosts: [Self.host("a", online: false)], ownHostID: "me") == .none)
  }

  @Test func aSavedHostStaysEvenWhenOthersAreOnline() {
    let hosts = [Self.host("a", online: true), Self.host("b", online: true), Self.host("mini", online: false)]
    #expect(RemoteHostChoice.decide(saved: "mini", hosts: hosts, ownHostID: "me") == .none)
  }

  @Test func aSavedHostMissingFromTheListAsks() {
    #expect(RemoteHostChoice.decide(saved: "gone", hosts: [Self.host("a", online: true)], ownHostID: "me") == .askUser)
  }

  @Test func aSavedHostMissingFromAnEmptyListAsks() {
    #expect(RemoteHostChoice.decide(saved: "gone", hosts: [], ownHostID: "me") == .askUser)
  }

  @Test func exactlyOneOtherOnlineHostIsSelected() {
    let hosts = [Self.host("me", online: true), Self.host("a", online: true), Self.host("b", online: false)]
    #expect(RemoteHostChoice.decide(saved: nil, hosts: hosts, ownHostID: "me") == .select("a"))
  }

  @Test func theOnlyOnlineHostIsSelectedWithoutAnOwnId() {
    let hosts = [Self.host("office", online: true), Self.host("mini", online: false)]
    #expect(RemoteHostChoice.decide(saved: nil, hosts: hosts, ownHostID: nil) == .select("office"))
  }

  @Test func noneOrSeveralOnlineAsks() {
    #expect(RemoteHostChoice.decide(saved: nil, hosts: [Self.host("me", online: true)], ownHostID: "me") == .askUser)
    let two = [Self.host("a", online: true), Self.host("b", online: true)]
    #expect(RemoteHostChoice.decide(saved: nil, hosts: two, ownHostID: "me") == .askUser)
    #expect(RemoteHostChoice.decide(saved: nil, hosts: [Self.host("mini", online: false)], ownHostID: "me") == .askUser)
    #expect(RemoteHostChoice.decide(saved: nil, hosts: [], ownHostID: "me") == .askUser)
  }

  @Test func thisMacIsNeverASavedChoice() {
    let hosts = [Self.host("me", online: true), Self.host("a", online: true)]
    #expect(RemoteHostChoice.decide(saved: "me", hosts: hosts, ownHostID: "me") == .askUser)
  }

  @Test func thePickerLeavesThisMacOut() {
    let hosts = [Self.host("me", online: true), Self.host("a", online: true)]
    #expect(RemoteHostChoice.pickable(hosts, ownHostID: "me").map(\.id) == ["a"])
    #expect(RemoteHostChoice.pickable(hosts, ownHostID: nil).map(\.id) == ["me", "a"])
  }

  // MARK: Awaiting tracker

  /// One repo, one worktree and one tab per content id; the listed ones have an agent that waits.
  static func repos(
    all: [String], awaiting: Set<String>, worktreeTitle: String? = "Remote access", tabTitle: String? = nil
  ) -> [RemoteClientRepository] {
    let tabs = all.map { contentId in
      RemoteClientTab(
        id: "t-\(contentId)", contentId: contentId, title: tabTitle ?? "tab \(contentId)",
        agents: [
          RemoteClientAgent(agent: "claude", activity: awaiting.contains(contentId) ? "awaitingInput" : "busy")
        ])
    }
    return [
      RemoteClientRepository(
        id: "r", name: "supacode",
        worktrees: [RemoteClientWorktree(id: "w", name: "remote-access", title: worktreeTitle, tabs: tabs)])
    ]
  }

  @Test func theFirstSnapshotStartsNothing() {
    var tracker = RemoteAwaitingTracker()
    #expect(tracker.update(Self.repos(all: ["t1"], awaiting: ["t1"])) == .init(started: [], ended: []))
  }

  @Test func aTabThatStartsToWaitIsReportedOnce() {
    var tracker = RemoteAwaitingTracker()
    _ = tracker.update(Self.repos(all: ["t1"], awaiting: []))
    #expect(tracker.update(Self.repos(all: ["t1"], awaiting: ["t1"])).started.map(\.contentId) == ["t1"])
    #expect(tracker.update(Self.repos(all: ["t1"], awaiting: ["t1"])).started.isEmpty)
    #expect(tracker.update(Self.repos(all: ["t1"], awaiting: ["t1"])).started.isEmpty)
  }

  @Test func aTabThatStopsOrVanishesEnds() {
    var tracker = RemoteAwaitingTracker()
    _ = tracker.update(Self.repos(all: ["t1", "t2"], awaiting: []))
    _ = tracker.update(Self.repos(all: ["t1", "t2"], awaiting: ["t1", "t2"]))
    #expect(Set(tracker.update(Self.repos(all: ["t1"], awaiting: [])).ended) == ["t1", "t2"])
  }

  @Test func aSecondWaitAfterLeavingIsANewNotification() {
    var tracker = RemoteAwaitingTracker()
    _ = tracker.update(Self.repos(all: ["a"], awaiting: []))
    _ = tracker.update(Self.repos(all: ["a"], awaiting: ["a"]))
    #expect(tracker.update(Self.repos(all: ["a"], awaiting: [])).ended == ["a"])
    #expect(tracker.update(Self.repos(all: ["a"], awaiting: ["a"])).started.map(\.contentId) == ["a"])
  }

  @Test func aVanishedTabIsForgottenSoItsNextWaitIsNew() {
    var tracker = RemoteAwaitingTracker()
    _ = tracker.update([])
    _ = tracker.update(Self.repos(all: ["a"], awaiting: ["a"]))
    #expect(tracker.update([]).ended == ["a"])
    #expect(tracker.update(Self.repos(all: ["a"], awaiting: ["a"])).started.map(\.contentId) == ["a"])
  }

  @Test func everyTabIsTrackedOnItsOwn() {
    var tracker = RemoteAwaitingTracker()
    _ = tracker.update(Self.repos(all: ["a", "b"], awaiting: []))
    #expect(tracker.update(Self.repos(all: ["a", "b"], awaiting: ["a"])).started.map(\.contentId) == ["a"])
    #expect(tracker.update(Self.repos(all: ["a", "b"], awaiting: ["a", "b"])).started.map(\.contentId) == ["b"])
  }

  @Test func oneWaitingAgentIsEnoughAndTheOtherLeavingChangesNothing() {
    var tracker = RemoteAwaitingTracker()
    func repos(_ activities: [String]) -> [RemoteClientRepository] {
      let agents = activities.map { RemoteClientAgent(agent: "claude", activity: $0) }
      let tab = RemoteClientTab(id: "t", contentId: "a", title: "tab a", agents: agents)
      return [
        RemoteClientRepository(id: "r", worktrees: [RemoteClientWorktree(id: "w", tabs: [tab])])
      ]
    }
    _ = tracker.update(repos(["idle"]))
    #expect(tracker.update(repos(["busy", "awaitingInput"])).started.map(\.contentId) == ["a"])
    #expect(tracker.update(repos(["awaitingInput", "awaitingInput"])) == .init(started: [], ended: []))
    #expect(tracker.update(repos(["busy", "awaitingInput"])) == .init(started: [], ended: []))
  }

  @Test func aStartedTabCarriesTheNotificationData() {
    var tracker = RemoteAwaitingTracker()
    _ = tracker.update(Self.repos(all: ["c"], awaiting: []))
    let tab = tracker.update(Self.repos(all: ["c"], awaiting: ["c"])).started.first
    #expect(
      tab
        == RemoteAwaitingTab(
          contentId: "c", repositoryId: "r", worktreeId: "w", worktreeName: "Remote access", tabTitle: "tab c",
          agent: "claude"))
  }

  @Test func theWorktreeNameFallsBackWhenTheTitleIsMissingOrBlank() {
    for title in [nil, "", "   "] {
      var tracker = RemoteAwaitingTracker()
      _ = tracker.update(Self.repos(all: ["c"], awaiting: [], worktreeTitle: title))
      let tab = tracker.update(Self.repos(all: ["c"], awaiting: ["c"], worktreeTitle: title)).started.first
      #expect(tab?.worktreeName == "remote-access")
    }
  }

  @Test func aBlankTabTitleIsTab() {
    var tracker = RemoteAwaitingTracker()
    _ = tracker.update(Self.repos(all: ["c"], awaiting: [], tabTitle: " "))
    let tab = tracker.update(Self.repos(all: ["c"], awaiting: ["c"], tabTitle: " ")).started.first
    #expect(tab?.tabTitle == "Tab")
  }

  @Test func resetForgetsAndTheNextSnapshotStartsNothing() {
    var tracker = RemoteAwaitingTracker()
    _ = tracker.update(Self.repos(all: ["t1"], awaiting: []))
    _ = tracker.update(Self.repos(all: ["t1"], awaiting: ["t1"]))
    #expect(tracker.reset() == ["t1"])
    #expect(tracker.update(Self.repos(all: ["t1"], awaiting: ["t1"])).started.isEmpty)
  }

  @Test func aResetAfterNothingReturnsNothingAndTheNewMacStartsClean() {
    var tracker = RemoteAwaitingTracker()
    #expect(tracker.reset().isEmpty)
    _ = tracker.update(Self.repos(all: ["a"], awaiting: ["a"]))
    #expect(tracker.reset() == ["a"])
    // After the reset the first snapshot records only; the second one reports a real transition.
    _ = tracker.update(Self.repos(all: ["a"], awaiting: []))
    #expect(tracker.update(Self.repos(all: ["a"], awaiting: ["a"])).started.map(\.contentId) == ["a"])
  }
}
