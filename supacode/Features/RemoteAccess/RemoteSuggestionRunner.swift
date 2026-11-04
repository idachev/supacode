import ConcurrencyExtras
import Foundation
import SupacodeSettingsShared

nonisolated private let suggestionLogger = SupaLogger("RemoteAccess")

/// Asks Sonnet 5.5 through the user's own `claude -p` login what to type next,
/// from the last lines of a terminal. It only returns text; the phone puts a
/// suggestion in its input field and never sends one on its own.
nonisolated enum RemoteSuggestionRunner {
  static let model = "claude-sonnet-5-5"
  static let maxSuggestions = 3
  static let timeout: Duration = .seconds(90)

  enum Failure: Error, Equatable {
    case launchFailed
    case timedOut
    case exitStatus(Int32)
    case unparseable
  }

  static func prompt(terminalText: String) -> String {
    """
    You help a developer who drives a terminal from a phone. Below are the last lines of one \
    terminal. It is either a plain shell or a coding agent's interface (Claude Code, Codex, ...). \
    Suggest up to \(maxSuggestions) short, useful things the developer could type next: a shell \
    command, an answer to the agent's question, a slash command, or a short instruction for the \
    agent. Each suggestion is the exact text to type, one line, without a trailing newline. \
    Reply with ONLY a JSON array of strings and nothing else.

    <terminal>
    \(terminalText)
    </terminal>
    """
  }

  /// Pulls the first JSON string array out of the model's reply, trims each
  /// entry, drops empty and duplicate ones, and keeps at most `maxSuggestions`.
  static func parse(_ reply: String) -> [String]? {
    guard let open = reply.firstIndex(of: "["), let close = reply.lastIndex(of: "]"), open < close else {
      return nil
    }
    let slice = String(reply[open...close])
    guard let decoded = try? JSONDecoder().decode([String].self, from: Data(slice.utf8)) else { return nil }
    var seen = Set<String>()
    let cleaned = decoded.compactMap { entry -> String? in
      let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
      return trimmed
    }
    return Array(cleaned.prefix(maxSuggestions))
  }

  /// Runs `claude -p` in the user's login shell (so `PATH` and the Claude
  /// login resolve as in a terminal), with hooks, MCP servers, slash commands
  /// and tools off: the call only reads the prompt and answers.
  static func suggest(terminalText: String) async throws -> [String] {
    let reply = try await run(prompt: prompt(terminalText: terminalText))
    guard let suggestions = parse(reply) else {
      suggestionLogger.warning("Unparseable suggestion reply: \(reply.prefix(200))")
      throw Failure.unparseable
    }
    return suggestions
  }

  private static func run(prompt: String) async throws -> String {
    let command =
      "claude -p --model \(model) --output-format text --no-session-persistence "
      + "--settings '{\"disableAllHooks\":true}' --disable-slash-commands --strict-mcp-config --tools ''"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", command]
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    let output = LockIsolated(Data())
    stdout.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      output.withValue { $0.append(chunk) }
    }
    let exit = AsyncStream<Int32> { continuation in
      process.terminationHandler = { finished in
        continuation.yield(finished.terminationStatus)
        continuation.finish()
      }
    }
    do {
      try process.run()
    } catch {
      suggestionLogger.warning("claude -p failed to launch: \(error)")
      throw Failure.launchFailed
    }
    stdin.fileHandleForWriting.write(Data(prompt.utf8))
    try? stdin.fileHandleForWriting.close()

    let status = await withTaskGroup(of: Int32?.self) { group -> Int32? in
      group.addTask {
        for await status in exit { return status }
        return nil
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return nil
      }
      defer { group.cancelAll() }
      return await group.next() ?? nil
    }
    guard let status else {
      if process.isRunning { process.terminate() }
      throw Failure.timedOut
    }
    guard status == 0 else { throw Failure.exitStatus(status) }
    // The readability handler may still hold the last chunk; drain what is left.
    stdout.fileHandleForReading.readabilityHandler = nil
    let rest = (try? stdout.fileHandleForReading.readToEnd()) ?? nil
    if let rest { output.withValue { $0.append(rest) } }
    return String(bytes: output.value, encoding: .utf8) ?? ""
  }
}
