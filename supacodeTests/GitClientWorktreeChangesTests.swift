import Foundation
import Testing

@testable import SupacodeSettingsShared
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
          == "the worktree has uncommitted changes, untracked or ignored files (2): "
          + changes.paths.joined(separator: ", ")
          + "; commit, stash or remove them on the Mac first")
    }
  }

  @Test func anIgnoredFileIsDirtyButAWhollyIgnoredGeneratedDirectoryIsNot() async throws {
    try await withRepository(gitignore: ".env\nnode_modules/\n.build/\n") { repo in
      try Self.writeFile(repo, "node_modules/pkg/index.js")
      try Self.writeFile(repo, ".build/debug/app")
      #expect(try await GitClient().worktreeChanges(at: repo) == WorktreeDirtyState())
      try "SECRET=1".write(to: repo.appending(path: ".env"), atomically: true, encoding: .utf8)
      #expect(try await GitClient().worktreeChanges(at: repo).paths == [".env"])
    }
  }

  @Test func aWhollyIgnoredDataDirectoryIsDirty() async throws {
    try await withRepository(gitignore: "data/\nnode_modules/\n") { repo in
      try Self.writeFile(repo, "node_modules/pkg/index.js")
      try Self.writeFile(repo, "data/results.csv")
      let changes = try await GitClient().worktreeChanges(at: repo)
      #expect(changes.paths == ["data/"])
      #expect(
        changes.message
          == "the worktree has uncommitted changes, untracked or ignored files (1): data/; "
          + "commit, stash or remove them on the Mac first")
    }
  }

  @Test func aNestedGeneratedDirectoryIsClean() async throws {
    try await withRepository(gitignore: "node_modules/\n") { repo in
      try Self.writeFile(repo, "packages/x/package.json")
      let path = repo.path(percentEncoded: false)
      try await Self.runGit(["-C", path, "add", "."])
      try await Self.runGit(["-C", path, "commit", "-m", "package"])
      try Self.writeFile(repo, "packages/x/node_modules/pkg/index.js")
      #expect(try await GitClient().worktreeChanges(at: repo) == WorktreeDirtyState())
    }
  }

  @Test func aDetachedCommitOnNoRefIsDirtyButUnpushedBranchCommitsAreNot() async throws {
    try await withRepository { repo in
      let path = repo.path(percentEncoded: false)
      // Unpushed commits on a branch: the branch keeps them.
      try "two".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
      try await Self.runGit(["-C", path, "commit", "-am", "two"])
      #expect(try await GitClient().worktreeChanges(at: repo) == WorktreeDirtyState())
      // A commit made on a detached HEAD is held by no ref.
      try await Self.runGit(["-C", path, "checkout", "--detach"])
      try "three".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
      try await Self.runGit(["-C", path, "commit", "-am", "three"])
      let changes = try await GitClient().worktreeChanges(at: repo)
      #expect(changes == WorktreeDirtyState(paths: [], detachedCommits: 1))
      #expect(
        changes.message
          == "the worktree's detached HEAD has 1 commits that are on no branch; "
          + "create a branch for them on the Mac first")
    }
  }

  @Test func anIgnoredFileInANestedSubmoduleIsDirtyWithItsPrefixedPath() async throws {
    try await withRepository(gitignore: ".env\nnode_modules/\ndata/\n") { inner in
      try await withRepository { middle in
        try await withRepository { outer in
          let allowFile = ["-c", "protocol.file.allow=always"]
          let middlePath = middle.path(percentEncoded: false)
          let outerPath = outer.path(percentEncoded: false)
          let innerPath = inner.path(percentEncoded: false)
          try await Self.runGit(allowFile + ["-C", middlePath, "submodule", "add", innerPath, "core"])
          try await Self.runGit(["-C", middlePath, "commit", "-m", "add core"])
          try await Self.runGit(allowFile + ["-C", outerPath, "submodule", "add", middlePath, "libs"])
          try await Self.runGit(["-C", outerPath, "commit", "-m", "add libs"])
          try await Self.runGit(allowFile + ["-C", outerPath, "submodule", "update", "--init", "--recursive"])
          // The innermost module ignores `.env` with its own committed `.gitignore`.
          let core = outer.appending(path: "libs/core")
          #expect(try await GitClient().worktreeChanges(at: outer) == WorktreeDirtyState())
          try "SECRET=1".write(to: core.appending(path: ".env"), atomically: true, encoding: .utf8)
          #expect(try await GitClient().worktreeChanges(at: outer).paths == ["libs/core/.env"])
          // Same directory rule inside a submodule: generated output is clean, data is not.
          try FileManager.default.removeItem(at: core.appending(path: ".env"))
          try Self.writeFile(core, "node_modules/pkg/index.js")
          #expect(try await GitClient().worktreeChanges(at: outer) == WorktreeDirtyState())
          try Self.writeFile(core, "data/results.csv")
          #expect(try await GitClient().worktreeChanges(at: outer).paths == ["libs/core/data/"])
        }
      }
    }
  }

  @Test func countedPathsSkipTheRenameSourceAndGeneratedIgnoredDirectories() {
    let output = Data(
      "R  new.txt\0old.txt\0 M a.swift\0?? b.txt\0!! build/\0!! .env\0UU c.swift\0!! notes/\0!! web/dist/\0".utf8)
    #expect(
      WorktreeDirtyState.countedPaths(porcelainV1Z: output) == [
        "new.txt", "a.swift", "b.txt", ".env", "c.swift", "notes/",
      ])
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

  /// Over ssh the status bytes stay raw: a normalized string would trim the
  /// leading space of ` M a` and hide the change (Codex ZD10 r1 F1).
  @Test func overSSHAOneLetterTrackedChangeIsDirty() async throws {
    let base = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "0", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runDataImpl: { _, arguments, _ in
        arguments.joined(separator: " ").contains("submodule") ? Data() : Data(" M a\u{0}".utf8)
      }
    )
    let client = GitClient(shell: .ssh(host: RemoteHost(alias: "devbox"), base: base))
    let changes = try await client.worktreeChanges(at: URL(fileURLWithPath: "/srv/repo/feature"))
    #expect(changes.paths == ["a"])
    #expect(changes.isDirty)
  }

  // MARK: - Helpers

  /// Writes a small file at `relativePath` under `root`, creating its directories.
  private static func writeFile(_ root: URL, _ relativePath: String) throws {
    let file = root.appending(path: relativePath)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "x".write(to: file, atomically: true, encoding: .utf8)
  }

  /// A fresh repository with one commit on `main` (and a committed `.gitignore`
  /// when given), removed after `body`.
  private func withRepository(gitignore: String? = nil, _ body: (URL) async throws -> Void) async throws {
    let repo = URL(filePath: "/tmp", directoryHint: .isDirectory)
      .appending(path: "supacode-changes-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: repo) }
    let path = repo.path(percentEncoded: false)
    try await Self.runGit(["init", "-b", "main", path])
    try await Self.runGit(["-C", path, "config", "user.email", "test@example.com"])
    try await Self.runGit(["-C", path, "config", "user.name", "Test User"])
    try "hello".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
    if let gitignore {
      try gitignore.write(to: repo.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
    }
    try await Self.runGit(["-C", path, "add", "."])
    try await Self.runGit(["-C", path, "commit", "-m", "init"])
    try await body(repo)
  }

  /// Runs real git with no user or system config.
  @discardableResult
  private static func runGit(_ arguments: [String]) async throws -> String {
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
}

private struct GitCommandError: Error {
  let output: String
}
