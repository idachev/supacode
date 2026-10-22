import Testing

@testable import supacode

@MainActor
struct SidebarHighlightOrderingTests {
  private func candidate(
    _ id: String,
    branch: String,
    isNotified: Bool = false,
    classification: SidebarActiveClassification? = nil,
    rank: Int? = nil
  ) -> SidebarHighlightOrdering.Candidate {
    .init(
      id: WorktreeID(id), branchName: branch, isNotified: isNotified, classification: classification,
      activityRank: rank)
  }

  @Test func activeOrdersByActivityRankNewestFirstThenUnrankedAlphabetically() {
    let candidates = [
      candidate("a", branch: "alpha", classification: .running),
      candidate("old", branch: "old", classification: .agent, rank: 1),
      candidate("z", branch: "zulu", classification: .agent),
      candidate("new", branch: "new", classification: .agent, rank: 5),
    ]
    #expect(
      SidebarHighlightOrdering.orderedRowIDs(forPinned: false, prioritizeNotified: false, candidates: candidates)
        == ["new", "old", "a", "z"])
    // Pinned ignores the rank and stays alphabetical.
    #expect(
      SidebarHighlightOrdering.orderedRowIDs(forPinned: true, prioritizeNotified: false, candidates: candidates)
        == ["a", "new", "old", "z"])
  }

  @Test func unreadStillFloatsAboveNewerActivityWhenPrioritized() {
    let candidates = [
      candidate("new", branch: "new", classification: .agent, rank: 9),
      candidate("unread", branch: "unread", isNotified: true, classification: .unreadAgent, rank: 2),
    ]
    #expect(
      SidebarHighlightOrdering.orderedRowIDs(forPinned: false, prioritizeNotified: true, candidates: candidates)
        == ["unread", "new"])
    #expect(
      SidebarHighlightOrdering.orderedRowIDs(forPinned: false, prioritizeNotified: false, candidates: candidates)
        == ["new", "unread"])
  }

  @Test func activeDropsUnclassifiedRows() {
    let ids = SidebarHighlightOrdering.orderedRowIDs(
      forPinned: false,
      prioritizeNotified: false,
      candidates: [
        candidate("a", branch: "alpha"),
        candidate("b", branch: "beta", classification: .running),
      ]
    )
    #expect(ids == ["b"])
  }

  @Test func pinnedSortsAllRowsAlphabetically() {
    // Classification no longer affects order: every pinned row (classified or
    // not) interleaves purely alphabetically.
    let ids = SidebarHighlightOrdering.orderedRowIDs(
      forPinned: true,
      prioritizeNotified: false,
      candidates: [
        candidate("c", branch: "charlie"),
        candidate("a", branch: "alpha"),
        candidate("b", branch: "bravo", classification: .running),
      ]
    )
    #expect(ids == ["a", "b", "c"])
  }

  @Test func classificationDoesNotDriveOrder() {
    // High-severity classifications used to float to the top; now order is
    // strictly alphabetical regardless of classification.
    let ids = SidebarHighlightOrdering.orderedRowIDs(
      forPinned: false,
      prioritizeNotified: false,
      candidates: [
        candidate("running", branch: "running", classification: .running),
        candidate("errored", branch: "errored", classification: .errored),
        candidate("agent", branch: "agent", classification: .agent),
        candidate("awaiting", branch: "awaiting", classification: .awaiting),
      ]
    )
    #expect(ids == ["agent", "awaiting", "errored", "running"])
  }

  @Test func orderIsStableAcrossClassificationChanges() {
    // The whole point of #678: a row's position must not move when its agent
    // state (classification) changes, only when its name changes.
    let before = SidebarHighlightOrdering.orderedRowIDs(
      forPinned: false,
      prioritizeNotified: false,
      candidates: [
        candidate("a", branch: "alpha", classification: .running),
        candidate("b", branch: "bravo", classification: .awaiting),
      ]
    )
    let after = SidebarHighlightOrdering.orderedRowIDs(
      forPinned: false,
      prioritizeNotified: false,
      candidates: [
        candidate("a", branch: "alpha", classification: .errored),
        candidate("b", branch: "bravo", classification: .running),
      ]
    )
    #expect(before == ["a", "b"])
    #expect(after == before)
  }

  @Test func notifiedRowsFloatToTopWhenPrioritizing() {
    // Unread rows first (alphabetical among themselves), then the rest
    // alphabetical.
    let ids = SidebarHighlightOrdering.orderedRowIDs(
      forPinned: true,
      prioritizeNotified: true,
      candidates: [
        candidate("a", branch: "alpha"),
        candidate("z", branch: "zulu", isNotified: true),
        candidate("b", branch: "bravo"),
        candidate("m", branch: "mike", isNotified: true),
      ]
    )
    #expect(ids == ["m", "z", "a", "b"])
  }

  @Test func notifiedFlagIgnoredWhenNotPrioritizing() {
    let ids = SidebarHighlightOrdering.orderedRowIDs(
      forPinned: true,
      prioritizeNotified: false,
      candidates: [
        candidate("a", branch: "alpha"),
        candidate("z", branch: "zulu", isNotified: true),
        candidate("b", branch: "bravo", isNotified: true),
      ]
    )
    #expect(ids == ["a", "b", "z"])
  }

  @Test func alphabeticalTieBreakIsLocaleInsensitive() {
    // Case-insensitive alphabetical so "Bravo" and "bravo" don't flip across
    // system locales.
    let ids = SidebarHighlightOrdering.orderedRowIDs(
      forPinned: false,
      prioritizeNotified: false,
      candidates: [
        candidate("z", branch: "Zulu", classification: .running),
        candidate("a", branch: "alpha", classification: .running),
        candidate("b", branch: "Bravo", classification: .running),
      ]
    )
    #expect(ids == ["a", "b", "z"])
  }

  @Test func equalBranchNamesFallBackToIDForDeterminism() {
    // Two repos with the same branch name in a global section: the sort is not
    // stable, so `id` breaks the tie deterministically.
    let ids = SidebarHighlightOrdering.orderedRowIDs(
      forPinned: false,
      prioritizeNotified: false,
      candidates: [
        candidate("second", branch: "main", classification: .running),
        candidate("first", branch: "main", classification: .running),
      ]
    )
    #expect(ids == ["first", "second"])
  }

  @Test func pinnedAndActiveDoNotDuplicate() {
    // Active drops rows already in Pinned; the aggregator dedups before calling
    // this helper via the `excluding` set.
    let candidates: [SidebarHighlightOrdering.Candidate] = [
      candidate("shared", branch: "shared", classification: .running),
      candidate("active-only", branch: "active", classification: .agent),
    ]
    let activeIDs = SidebarHighlightOrdering.orderedRowIDs(
      forPinned: false,
      prioritizeNotified: false,
      candidates: candidates.filter { $0.id != "shared" }
    )
    #expect(activeIDs == ["active-only"])
  }

  @Test func emptyCandidatesYieldEmptyOrder() {
    #expect(
      SidebarHighlightOrdering.orderedRowIDs(forPinned: true, prioritizeNotified: false, candidates: []) == [])
    #expect(
      SidebarHighlightOrdering.orderedRowIDs(forPinned: false, prioritizeNotified: true, candidates: []) == [])
  }
}
