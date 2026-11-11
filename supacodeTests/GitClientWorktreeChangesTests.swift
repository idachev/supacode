import Foundation
import Testing

@testable import supacode

/// The dirty check of a remote `worktree.delete` (`GitClient.worktreeChanges`)
/// against real git repositories.
struct GitClientWorktreeChangesTests {
  @Test func aCleanWorktreeIsClean() async throws {
    try await withRepository { repo in
      let changes = try await GitClient().worktreeChanges(at: repo)
      #expect(changes == WorktreeDirtyState())
      #expect(!changes.isDirty)
      #expect(changes.message == nil)
    }
  }

  @Test func aTrackedChangeAndAnUntrackedFileAreDirty() async throws {
    try await withRepository { repo in
      try "changed".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
      try "new".write(to: repo.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
      let changes = try await GitClient().worktreeChanges(at: repo)
      #expect(Set(changes.paths) == ["README.md", "notes.txt"])
      #expect(
        changes.message
          == "the worktree has uncommitted changes, untracked or ignored files (2): \(changes.paths.joined(separator: ", "))"
          + "; commit, stash or remove them on the Mac first")
    }
  }

  @Test func anIgnoredFileIsDirtyButAWhollyIgnoredDirectoryIsNot() async throws {
    try await withRepository(gitignore: ".env\nnode_modules/\n") { repo in
      let modules = repo.appending(path: "node_modules/pkg")
      try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
      try "x".write(to: modules.appending(path: "index.js"), atomically: true, encoding: .utf8)
      #expect(try await GitClient().worktreeChanges(at: repo) == WorktreeDirtyState())
      try "SECRET=1".write(to: repo.appending(path: ".env"), atomically: true, encoding: .utf8)
      #expect(try await GitClient().worktreeChanges(at: repo).paths == [".env"])
    }
  }

  @Test func aDetachedCommitOnNoRefIsDirtyButUnpushedBranchCommitsAreNot() async throws {
    try await withRepository { repo in
      let path = repo.path(percentEncoded: false)
      // Unpushed commits on a branch: the branch keeps them.
      try "two".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
      try await runGit(["-C", path, "commit", "-am", "two"])
      #expect(try await GitClient().worktreeChanges(at: repo) == WorktreeDirtyState())
      // A commit made on a detached HEAD is held by no ref.
      try await runGit(["-C", path, "checkout", "--detach"])
      try "three".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
      try await runGit(["-C", path, "commit", "-am", "three"])
      let changes = try await GitClient().worktreeChanges(at: repo)
      #expect(changes == WorktreeDirtyState(paths: [], detachedCommits: 1))
      #expect(
        changes.message
          == "the worktree's detached HEAD has 1 commits that are on no branch; create a branch for them on the Mac first")
    }
  }

  @Test func anIgnoredFileInANestedSubmoduleIsDirtyWithItsPrefixedPath() async throws {
    try await withRepository(gitignore: ".env\n") { inner in
      try await withRepository { middle in
        try await withRepository { outer in
          let allowFile = ["-c", "protocol.file.allow=always"]
          let middlePath = middle.path(percentEncoded: false)
          let outerPath = outer.path(percentEncoded: false)
          try await runGit(allowFile + ["-C", middlePath, "submodule", "add", inner.path(percentEncoded: false), "core"])
          try await runGit(["-C", middlePath, "commit", "-m", "add core"])
          try await runGit(allowFile + ["-C", outerPath, "submodule", "add", middlePath, "libs"])
          try await runGit(["-C", outerPath, "commit", "-m", "add libs"])
          try await runGit(allowFile + ["-C", outerPath, "submodule", "update", "--init", "--recursive"])
          // The innermost module ignores `.env` with its own committed `.gitignore`.
          let core = outer.appending(path: "libs/core")
          #expect(try await GitClient().worktreeChanges(at: outer) == WorktreeDirtyState())
          try "SECRET=1".write(to: core.appending(path: ".env"), atomically: true, encoding: .utf8)
          #expect(try await GitClient().worktreeChanges(at: outer).paths == ["libs/core/.env"])
        }
      }
    }
  }

  @Test func countedPathsSkipTheRenameSourceAndIgnoredDirectories() {
    let output = Data("R  new.txt\0old.txt\0 M a.swift\0?? b.txt\0!! build/\0!! .env\0UU c.swift\0".utf8)
    #expect(
      WorktreeDirtyState.countedPaths(porcelainV1Z: output) == ["new.txt", "a.swift", "b.txt", ".env", "c.swift"])
    #expect(WorktreeDirtyState.countedPaths(porcelainV1Z: Data()) == [])
  }

  @Test func theMessageListsAtMostFivePathsAndJoinsBothReasons() {
    let state = WorktreeDirtyState(paths: ["a", "b", "c", "d", "e", "f"], detachedCommits: 2)
    #expect(
      state.message
        == "the worktree has uncommitted changes, untracked or ignored files (6): a, b, c, d, e; "
        + "commit, stash or remove them on the Mac first; "
        + "the worktree's detached HEAD has 2 commits that are on no branch; create a branch for them on the Mac first")
  }

  // MARK: - Helpers

  /// A fresh repository with one commit on `main` (and a committed `.gitignore`
  /// when given), removed after `body`.
  private func withRepository(gitignore: String? = nil, _ body: (URL) async throws -> Void) async throws {
    let repo = URL(filePath: "/tmp", directoryHint: .isDirectory)
      .appending(path: "supacode-changes-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: repo) }
    let path = repo.path(percentEncoded: false)
    try await runGit(["init", "-b", "main", path])
    try await runGit(["-C", path, "config", "user.email", "test@example.com"])
    try await runGit(["-C", path, "config", "user.name", "Test User"])
    try "hello".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
    if let gitignore {
      try gitignore.write(to: repo.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
    }
    try await runGit(["-C", path, "add", "."])
    try await runGit(["-C", path, "commit", "-m", "init"])
    try await body(repo)
  }
}

private struct GitCommandError: Error {
  let output: String
}

@discardableResult
private func runGit(_ arguments: [String]) async throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments = arguments
  // Hermetic git: the user's global config must not leak in.
  process.environment = ProcessInfo.processInfo.environment.merging([
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_SYSTEM": "/dev/null",
  ]) { _, override in override }
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  try await process.runToExit()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  let output = String(data: data, encoding: .utf8) ?? ""
  if process.terminationStatus != 0 {
    throw GitCommandError(output: output)
  }
  return output
}
