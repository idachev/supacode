import ArgumentParser
import Darwin
import Dispatch
import Foundation

/// The child process of a remote tab's Ghostty surface: copies the terminal's bytes to and from
/// the app over the app's private pipe socket. Hidden from `--help`; the app starts it.
struct RemotePipeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remote-pipe",
    abstract: "Pipe a remote terminal through the Supacode app.",
    shouldDisplay: false
  )

  @Argument(help: "The remote terminal's content id.")
  var contentID: String

  func run() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let socketPath = environment[RemotePipeWire.socketVariable], !socketPath.isEmpty,
      let token = environment[RemotePipeWire.tokenVariable], !token.isEmpty
    else {
      RemotePipeWire.fail(
        "\(RemotePipeWire.socketVariable) and \(RemotePipeWire.tokenVariable) must be set.")
    }
    let socketFD: Int32
    do {
      socketFD = try RemotePipeWire.connect(to: socketPath)
    } catch {
      RemotePipeWire.fail(error.message)
    }
    defer { close(socketFD) }

    // A dead socket or a closed terminal must end in EPIPE, not a signal that skips the restore.
    signal(SIGPIPE, SIG_IGN)
    signal(SIGWINCH, SIG_IGN)
    let terminal = RawTerminal.enter(STDIN_FILENO)
    defer { terminal?.restore() }

    let header = RemotePipeWire.header(token: token, contentID: contentID)
    guard RemotePipeWire.writeAll(header, to: socketFD) else { return }
    RemotePipeWire.copyUntilEitherSideEnds(socket: socketFD)
  }
}

/// The CLI's copy of the app's `RemotePipeProtocol` text (the CLI does not link the app module),
/// plus the blocking copy loops.
nonisolated enum RemotePipeWire {
  static let socketVariable = "SUPACODE_REMOTE_PIPE_SOCKET"
  static let tokenVariable = "SUPACODE_REMOTE_PIPE_TOKEN"

  struct ConnectError: Error {
    let message: String
  }

  /// "SUPACODE-PIPE 1 <token> <contentId>\n"
  static func header(token: String, contentID: String) -> [UInt8] {
    Array("SUPACODE-PIPE 1 \(token) \(contentID)\n".utf8)
  }

  /// One line on stderr, exit 1. Never called once the terminal is raw.
  static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("supacode remote-pipe: \(message)\n".utf8))
    Foundation.exit(1)
  }

  static func connect(to path: String) throws(ConnectError) -> Int32 {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      throw ConnectError(message: "socket path too long: \(path)")
    }
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
      pathBytes.withUnsafeBufferPointer { buffer in
        memcpy(sunPath, buffer.baseAddress!, buffer.count)
      }
    }
    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
      throw ConnectError(message: "socket() failed: \(String(cString: strerror(errno)))")
    }
    var enabled: Int32 = 1
    _ = setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
    let result = withUnsafePointer(to: &addr) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socketFD, $0, addrLen) }
    }
    guard result == 0 else {
      let code = errno
      close(socketFD)
      throw ConnectError(message: "cannot connect to \(path): \(String(cString: strerror(code)))")
    }
    return socketFD
  }

  /// stdin → socket and socket → stdout on two threads (macOS `poll` does not support ttys);
  /// returns as soon as either direction reaches EOF or fails. The other thread may stay blocked
  /// in `read` until the process exits.
  static func copyUntilEitherSideEnds(socket socketFD: Int32) {
    let ended = DispatchSemaphore(value: 0)
    let toSocket = Thread {
      copy(from: STDIN_FILENO, to: socketFD)
      ended.signal()
    }
    let toTerminal = Thread {
      copy(from: socketFD, to: STDOUT_FILENO)
      ended.signal()
    }
    toSocket.start()
    toTerminal.start()
    ended.wait()
  }

  private static func copy(from source: Int32, to destination: Int32) {
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { return }
      guard writeAll(Array(buffer[0..<count]), to: destination) else { return }
    }
  }

  @discardableResult
  static func writeAll(_ bytes: [UInt8], to fileDescriptor: Int32) -> Bool {
    bytes.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return true }
      var written = 0
      while written < raw.count {
        let result = write(fileDescriptor, base.advanced(by: written), raw.count - written)
        if result < 0, errno == EINTR { continue }
        guard result > 0 else { return false }
        written += result
      }
      return true
    }
  }
}

/// The terminal in raw mode, with its earlier attributes kept for `restore()`.
nonisolated struct RawTerminal {
  private let fileDescriptor: Int32
  private let original: termios

  /// nil when the descriptor is not a terminal or its attributes cannot be read or set.
  static func enter(_ fileDescriptor: Int32) -> RawTerminal? {
    guard isatty(fileDescriptor) == 1 else { return nil }
    var original = termios()
    guard tcgetattr(fileDescriptor, &original) == 0 else { return nil }
    var raw = original
    cfmakeraw(&raw)
    guard tcsetattr(fileDescriptor, TCSANOW, &raw) == 0 else { return nil }
    return RawTerminal(fileDescriptor: fileDescriptor, original: original)
  }

  func restore() {
    var attributes = original
    _ = tcsetattr(fileDescriptor, TCSANOW, &attributes)
  }
}
