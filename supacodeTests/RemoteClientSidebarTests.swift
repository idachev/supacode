import Foundation
import Testing

@testable import supacode

struct RemoteClientSidebarTests {
  typealias Model = RemoteSidebarModel

  // MARK: - Fixtures

  private static func worktree(
    _ id: String, name: String? = nil, branch: String? = nil, title: String? = nil, tabTitles: [String] = []
  ) -> RemoteClientWorktree {
    RemoteClientWorktree(
      id: id, name: name ?? id, branch: branch ?? "b-\(id)", status: "unpinned", title: title,
      tabs: tabTitles.enumerated().map { RemoteClientTab(id: "\(id)-t\($0.offset)", title: $0.element) })
  }

  private static func repo(
    _ id: String, name: String? = nil, worktrees: [RemoteClientWorktree], rowIds: [String]? = nil
  ) -> RemoteClientRepository {
    RemoteClientRepository(
      id: id, name: name ?? id, canCreateWorktree: true, worktrees: worktrees,
      rowIds: rowIds ?? worktrees.map(\.id))
  }

  private static func ids(_ sections: [Model.Section]) -> [String] { sections.map(\.id) }

  private static func rowIDs(_ sections: [Model.Section]) -> [[String]] {
    sections.map { $0.rows.map(\.id) }
  }

  /// Repos A (a1 main, a2 pinned, a3) and B (b1, b2 active) in a group, C (c1) ungrouped.
  private static let fullList = RemoteClientList(
    repos: [
      repo("A", worktrees: [worktree("a1"), worktree("a2"), worktree("a3")], rowIds: ["a1", "a3"]),
      repo("B", worktrees: [worktree("b1"), worktree("b2")], rowIds: ["b1"]),
      repo("C", worktrees: [worktree("c1")]),
    ],
    sections: [
      RemoteClientSection(kind: "active", title: "Active", worktreeIds: ["b2"]),
      RemoteClientSection(kind: "pinned", title: "Pinned", worktreeIds: ["a2"]),
      RemoteClientSection(kind: "group", title: "Work", collapsed: true, repositoryIds: ["A", "B"]),
      RemoteClientSection(kind: "repository", repositoryId: "C"),
    ])

  // MARK: - Tests

  @Test func sectionsFollowTheHostsOrder() {
    let sections = Model.sections(Self.fullList, filter: "")
    #expect(Self.ids(sections) == ["highlight:active", "highlight:pinned", "group:Work|A,B", "repository:C"])
    guard case .group(let title, let collapsed, let repositories) = sections[2] else {
      Issue.record("expected the group third")
      return
    }
    #expect(title == "Work")
    #expect(collapsed)
    #expect(repositories.map(\.id) == ["A", "B"])
    #expect(sections[0] == .highlight(kind: "active", title: "Active", rows: sections[0].rows))
  }

  @Test func repositoryRowsComeFromRowIdsWithoutHoistedOnes() {
    let sections = Model.sections(Self.fullList, filter: "")
    #expect(Self.rowIDs(sections) == [["b2"], ["a2"], ["a1", "a3", "b1"], ["c1"]])
    let row = sections[1].rows[0]
    #expect(row.repositoryID == "A")
    #expect(row.name == "a2")
    #expect(row.branch == "b-a2")
    #expect(row.status == "unpinned")
  }

  @Test func aPendingRowIdThatDoesNotResolveIsSkipped() {
    var list = Self.fullList
    list.repos[2].rowIds = ["pending:x", "c1"]
    list.sections[0].worktreeIds = ["pending:y", "b2"]
    let sections = Model.sections(list, filter: "")
    #expect(Self.rowIDs(sections) == [["b2"], ["a2"], ["a1", "a3", "b1"], ["c1"]])
  }

  @Test func loadFailuresBecomeSections() {
    var list = Self.fullList
    list.loadFailures = [RemoteClientLoadFailure(repositoryId: "D", message: "not a git repository")]
    let sections = Model.sections(list, filter: "")
    #expect(sections.last == .loadFailure(repositoryID: "D", message: "not a git repository"))
    #expect(sections.count == 5)
  }

  @Test func theFilterMatchesRepoWorktreeBranchAndTabTitle() {
    let list = RemoteClientList(
      repos: [
        Self.repo("R1", name: "Supacode", worktrees: [Self.worktree("x1"), Self.worktree("x2")]),
        Self.repo(
          "R2", name: "other",
          worktrees: [
            Self.worktree("y1", name: "Feature-Login"),
            Self.worktree("y2", branch: "fix/LOGIN-crash"),
            Self.worktree("y3", tabTitles: ["zsh", "claude login"]),
            Self.worktree("y4", title: "Login page"),
            Self.worktree("y5"),
          ]),
        Self.repo("R3", name: "third", worktrees: [Self.worktree("z1")]),
      ],
      sections: [
        RemoteClientSection(kind: "repository", repositoryId: "R1"),
        RemoteClientSection(kind: "repository", repositoryId: "R2"),
        RemoteClientSection(kind: "repository", repositoryId: "R3"),
      ])
    // Worktree name, branch, tab title and title, case-insensitive; R1 and R3 have no match.
    let login = Model.sections(list, filter: "  login ")
    #expect(Self.ids(login) == ["repository:R2"])
    #expect(Self.rowIDs(login) == [["y1", "y2", "y3", "y4"]])
    // A repository name keeps all its rows.
    let repoName = Model.sections(list, filter: "SUPA")
    #expect(Self.rowIDs(repoName) == [["x1", "x2"]])
    // No filter: every repository, an empty one included.
    var withEmpty = list
    withEmpty.repos[2].rowIds = []
    #expect(Self.rowIDs(Model.sections(withEmpty, filter: "")) == [["x1", "x2"], ["y1", "y2", "y3", "y4", "y5"], []])
  }

  @Test func anUnknownSectionKindIsSkipped() {
    var list = Self.fullList
    list.sections.insert(RemoteClientSection(kind: "future", title: "Later", worktreeIds: ["a1"]), at: 1)
    let sections = Model.sections(list, filter: "")
    #expect(Self.ids(sections) == ["highlight:active", "highlight:pinned", "group:Work|A,B", "repository:C"])
  }

  @Test func aListWithoutSectionsShowsEveryRepository() {
    let list = RemoteClientList(repos: [Self.repo("A", worktrees: [Self.worktree("a1")], rowIds: [])])
    #expect(Self.rowIDs(Model.sections(list, filter: "")) == [["a1"]])
  }
}
