import Foundation
import Testing

@testable import supacode

struct RemoteAccessSnapshotBuilderTests {
  private func worktree(
    _ id: String,
    _ status: SidebarState.WorktreeStatus,
    index: Int?,
    tabs: [RemoteTab] = []
  ) -> RemoteSnapshotBuilder.WorktreeInput {
    .init(
      id: id, name: id, branch: id, status: status, focused: false, title: nil,
      sidebarIndex: index, tabs: tabs)
  }

  private func tab(_ id: String, working: Bool) -> RemoteTab {
    RemoteTab(id: id, contentId: "c-\(id)", title: id, focused: false, working: working, readOnly: false, agents: [])
  }

  @Test func ordersLikeTheSidebarAndDropsArchived() {
    let repositories = RemoteSnapshotBuilder.build(repositories: [
      .init(
        id: "r1", name: "repo",
        worktrees: [
          worktree("u-unlisted", .unpinned, index: nil),
          worktree("u1", .unpinned, index: 1),
          worktree("archived", .archived, index: 0),
          worktree("p1", .pinned, index: 1),
          worktree("u0", .unpinned, index: 0),
          worktree("main", .main, index: nil),
          worktree("p0", .pinned, index: 0),
        ])
    ])
    #expect(repositories.map(\.id) == ["r1"])
    #expect(repositories[0].worktrees.map(\.id) == ["main", "p0", "p1", "u0", "u1", "u-unlisted"])
    #expect(repositories[0].worktrees.map(\.status) == ["main", "pinned", "pinned", "unpinned", "unpinned", "unpinned"])
  }

  @Test func worktreeIsWorkingWhenAnyTabIs() {
    let repositories = RemoteSnapshotBuilder.build(repositories: [
      .init(
        id: "r", name: "r",
        worktrees: [
          worktree("busy", .unpinned, index: 0, tabs: [tab("a", working: false), tab("b", working: true)]),
          worktree("idle", .unpinned, index: 1, tabs: [tab("c", working: false)]),
        ])
    ])
    #expect(repositories[0].worktrees.map(\.working) == [true, false])
    #expect(repositories[0].worktrees[0].tabs.map(\.contentId) == ["c-a", "c-b"])
  }

  @Test func listMessageEncodesTheProtocolShape() throws {
    let message = RemoteListMessage(
      id: 1,
      repos: [
        RemoteRepository(
          id: "r", name: "supacode",
          worktrees: [
            RemoteWorktree(
              id: "w", name: "main", branch: "main", status: "main", focused: true, title: nil, working: false,
              tabs: [
                RemoteTab(
                  id: "t", contentId: "c", title: "claude", focused: true, working: false, readOnly: false,
                  agents: [RemoteAgent(agent: "claude", activity: "awaitingInput")])
              ])
          ])
      ])
    let json = try #require(try JSONSerialization.jsonObject(with: RemoteJSON.encode(message)) as? [String: Any])
    #expect(json["t"] as? String == "list")
    let repo = try #require((json["repos"] as? [[String: Any]])?.first)
    let worktree = try #require((repo["worktrees"] as? [[String: Any]])?.first)
    let tab = try #require((worktree["tabs"] as? [[String: Any]])?.first)
    #expect(tab["contentId"] as? String == "c")
    #expect((tab["agents"] as? [[String: String]])?.first == ["agent": "claude", "activity": "awaitingInput"])
  }

  @Test func sectionsOmitAbsentFields() throws {
    let message = RemoteListMessage(
      id: nil, repos: [],
      sections: [
        RemoteSection(kind: "active", title: "Active", worktreeIds: ["w1"]),
        RemoteSection(kind: "repository", repositoryId: "r1"),
      ])
    let json = try #require(try JSONSerialization.jsonObject(with: RemoteJSON.encode(message)) as? [String: Any])
    let sections = try #require(json["sections"] as? [[String: Any]])
    #expect(Set(sections[0].keys) == ["kind", "title", "worktreeIds"])
    #expect(Set(sections[1].keys) == ["kind", "repositoryId"])
  }
}
