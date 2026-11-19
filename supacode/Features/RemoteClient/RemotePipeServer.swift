import Darwin
import Dispatch
import Foundation
import SupacodeSettingsShared

nonisolated private let pipeLogger = SupaLogger("RemotePipe")

/// The text both ends of a remote pipe agree on. The CLI target (`supacode remote-pipe`) keeps its
/// own copy of the two variable names and the header format; `RemoteClientPipeTests` pins it.
nonisolated enum RemotePipeProtocol {
  static let socketVariable = "SUPACODE_REMOTE_PIPE_SOCKET"
  static let tokenVariable = "SUPACODE_REMOTE_PIPE_TOKEN"
  static let magic = "SUPACODE-PIPE"
  static let version = "1"

  /// "SUPACODE-PIPE 1 <token> <contentId>\n"
  static func header(token: String, contentID: String) -> [UInt8] {
    Array("\(magic) \(version) \(token) \(contentID)\n".utf8)
  }

  /// nil unless the line is exactly a version-1 header.
  static func parseHeader(_ line: String) -> (token: String, contentID: String)? {
    let fields = line.split(separator: " ", omittingEmptySubsequences: false)
    guard fields.count == 4, fields[0] == magic, fields[1] == version else { return nil }
    let token = String(fields[2])
    let contentID = String(fields[3])
    guard Self.isWord(token), Self.isWord(contentID) else { return nil }
    return (token, contentID)
  }

  /// A non-empty field of printable ASCII with no space.
  private static func isWord(_ field: String) -> Bool {
    !field.isEmpty && field.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F }
  }
}

/// The app's end of the byte pipes between local Ghostty surfaces and remote terminals.
///
/// A remote tab is a Ghostty surface whose child is `supacode remote-pipe <contentId>`. That
/// process connects to this unix socket, sends the version-1 header with the one-time token from
/// its environment, and then copies the terminal's bytes both ways. A connection with a bad header,
/// an unknown token or a content that already has a pipe is closed at once and reports nothing.
///
/// Accept, read and write run on a private queue; only the callbacks and the token table live on the
/// main actor. Every hop to the main actor goes through `DispatchQueue.main` so a pipe's events keep
/// their order: `onOpened`, then `onInput` chunks, then exactly one `onClosed`.
@MainActor
final class RemotePipeServer {
  nonisolated enum StartError: Error, Equatable {
    case directory
    case pathTooLong
    case socket(errno: Int32)
    case bind(errno: Int32)
    case listen(errno: Int32)
  }

  let directory: URL
  let socketPath: String

  var onOpened: (@MainActor (_ contentID: String) -> Void)?
  var onInput: (@MainActor (_ contentID: String, _ bytes: [UInt8]) -> Void)?
  var onClosed: (@MainActor (_ contentID: String) -> Void)?

  private var hub: RemotePipeHub?
  /// contentID → the one token that may open its pipe.
  private var expected: [String: String] = [:]
  private var pipes: [String: RemotePipeConnection] = [:]

  /// A unix socket `remote-pipe-<pid>.sock`, mode 0600, in `directory` (the CLI socket's directory:
  /// its path is short enough for `sun_path`).
  init(directory: URL) {
    self.directory = directory
    let pid = ProcessInfo.processInfo.processIdentifier
    socketPath = directory.appending(path: "remote-pipe-\(pid).sock").path(percentEncoded: false)
  }

  /// Released without `stop()`: the listener and every pipe close (no callbacks) and the file goes.
  nonisolated deinit {
    guard let hub else { return }
    hub.shutdown()
    unlink(socketPath)
  }

  /// Listens on `socketPath`, replacing a stale file there. Does nothing while already listening.
  func start() throws {
    guard hub == nil else { return }
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      pipeLogger.warning("Failed to create the pipe socket directory")
      throw StartError.directory
    }
    hub = try RemotePipeHub(path: socketPath) { [weak self] connection, event in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self?.handle(event, from: connection)
        }
      }
    }
    pipeLogger.info("Pipe socket listening")
  }

  /// Closes the listener and every pipe (each open pipe's `onClosed` fires), drops every token
  /// and removes the socket file.
  func stop() {
    guard let hub else { return }
    self.hub = nil
    hub.shutdown()
    unlink(socketPath)
    expected = [:]
    let open = pipes
    pipes = [:]
    for contentID in open.keys.sorted() {
      onClosed?(contentID)
    }
  }

  /// A one-time token for the pipe of this content; the surface gets it in its environment.
  /// A new call replaces the content's earlier unused token.
  func expect(contentID: String) -> String {
    let token = Self.makeToken()
    expected[contentID] = token
    return token
  }

  /// Drops the content's token and closes its open pipe (its `onClosed` fires).
  func forget(contentID: String) {
    expected[contentID] = nil
    guard let connection = pipes.removeValue(forKey: contentID) else { return }
    connection.close()
    onClosed?(contentID)
  }

  /// Bytes for the local terminal. Dropped while that content has no open pipe.
  func write(contentID: String, _ bytes: [UInt8]) {
    guard !bytes.isEmpty, let connection = pipes[contentID] else { return }
    connection.write(bytes)
  }

  private func handle(_ event: RemotePipeConnection.Event, from connection: RemotePipeConnection) {
    switch event {
    case .header(let token, let contentID):
      guard hub != nil, pipes[contentID] == nil, let wanted = expected[contentID], wanted == token
      else {
        pipeLogger.info("Pipe connection refused")
        connection.close()
        return
      }
      expected[contentID] = nil
      pipes[contentID] = connection
      // Before `onOpened`: a write from the callback queues after the activation, not before it.
      // Buffered input still reports after `onOpened`, through a later main-queue block.
      connection.activate()
      onOpened?(contentID)
    case .input(let contentID, let bytes):
      guard pipes[contentID] === connection else { return }
      onInput?(contentID, bytes)
    case .closed(let contentID):
      guard pipes[contentID] === connection else { return }
      pipes[contentID] = nil
      onClosed?(contentID)
    }
  }

  /// 32 random bytes as lowercase hex: no spaces, safe in an environment variable and a header.
  private static func makeToken() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
      .joined()
  }
}

/// The listening socket and the accepted connections. Created on the main actor; after `init`
/// every mutable field is touched only on `queue`.
nonisolated final class RemotePipeHub: @unchecked Sendable {
  typealias Report = @Sendable (RemotePipeConnection, RemotePipeConnection.Event) -> Void

  private let queue = DispatchQueue(label: "app.supabit.supacode.remote-pipe")
  private let listenFD: Int32
  private let source: DispatchSourceRead
  private let report: Report
  /// Queue-confined.
  private var connections: [ObjectIdentifier: RemotePipeConnection] = [:]
  /// Queue-confined.
  private var stopped = false

  init(path: String, report: @escaping Report) throws {
    self.report = report
    let socketFD = try Self.listeningSocket(path: path)
    listenFD = socketFD
    source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
    source.setEventHandler { [weak self] in self?.acceptPending() }
    source.setCancelHandler { close(socketFD) }
    source.activate()
  }

  deinit {}

  /// Stops accepting and closes every connection without reporting.
  func shutdown() {
    queue.async { [self] in
      guard !stopped else { return }
      stopped = true
      source.cancel()
      let open = Array(connections.values)
      connections = [:]
      for connection in open {
        connection.closeNow()
      }
    }
  }

  private func acceptPending() {
    while !stopped {
      let clientFD = accept(listenFD, nil, nil)
      guard clientFD >= 0 else {
        let code = errno
        if code == EINTR { continue }
        if code != EAGAIN, code != EWOULDBLOCK, code != ECONNABORTED {
          pipeLogger.warning("accept() failed: \(String(cString: strerror(code)))")
        }
        return
      }
      Self.configureClient(clientFD)
      let connection = RemotePipeConnection(fileDescriptor: clientFD, queue: queue, report: report)
      let key = ObjectIdentifier(connection)
      connections[key] = connection
      connection.start { [weak self] in
        self?.connections[key] = nil
      }
    }
  }

  private static func configureClient(_ fileDescriptor: Int32) {
    _ = fcntl(fileDescriptor, F_SETFD, FD_CLOEXEC)
    var enabled: Int32 = 1
    _ = setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
  }

  private static func listeningSocket(path: String) throws -> Int32 {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      pipeLogger.warning("Pipe socket path too long")
      throw RemotePipeServer.StartError.pathTooLong
    }
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
      pathBytes.withUnsafeBufferPointer { buffer in
        memcpy(sunPath, buffer.baseAddress!, buffer.count)
      }
    }

    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFD >= 0 else { throw RemotePipeServer.StartError.socket(errno: errno) }
    _ = fcntl(socketFD, F_SETFD, FD_CLOEXEC)

    unlink(path)
    let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
    let bindResult = withUnsafePointer(to: &addr) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, addrLen) }
    }
    guard bindResult == 0 else {
      let code = errno
      close(socketFD)
      pipeLogger.warning("Pipe socket bind() failed: \(String(cString: strerror(code)))")
      throw RemotePipeServer.StartError.bind(errno: code)
    }
    // Before listen(): no client can connect while the file still has the umask's mode.
    guard chmod(path, 0o600) == 0 else {
      let code = errno
      close(socketFD)
      unlink(path)
      throw RemotePipeServer.StartError.bind(errno: code)
    }
    let flags = fcntl(socketFD, F_GETFL)
    guard flags >= 0, fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) == 0, listen(socketFD, 16) == 0 else {
      let code = errno
      close(socketFD)
      unlink(path)
      pipeLogger.warning("Pipe socket listen() failed: \(String(cString: strerror(code)))")
      throw RemotePipeServer.StartError.listen(errno: code)
    }
    return socketFD
  }
}

/// One accepted connection. Every mutable field is touched only on `queue`; the `DispatchIO`
/// channel owns the descriptor and closes it in its cleanup handler.
nonisolated final class RemotePipeConnection: @unchecked Sendable {
  enum Event: Sendable {
    case header(token: String, contentID: String)
    case input(contentID: String, bytes: [UInt8])
    case closed(contentID: String)
  }

  private enum Phase {
    /// Reading the header line.
    case header([UInt8])
    /// The header went to the main actor; bytes after it wait here until `activate()`.
    case pending(contentID: String, buffered: [UInt8], ended: Bool)
    case open(contentID: String)
    case closed
  }

  /// Longest header accepted; a longer line closes the connection.
  static let maximumHeaderLength = 512
  /// A client that has not finished its header by then is closed.
  static let headerTimeout: DispatchTimeInterval = .seconds(5)

  private let fileDescriptor: Int32
  private let queue: DispatchQueue
  private let report: RemotePipeHub.Report
  /// Queue-confined.
  private var channel: DispatchIO?
  /// Queue-confined.
  private var phase: Phase = .header([])
  /// Queue-confined.
  private var onTerminated: (@Sendable () -> Void)?

  init(fileDescriptor: Int32, queue: DispatchQueue, report: @escaping RemotePipeHub.Report) {
    self.fileDescriptor = fileDescriptor
    self.queue = queue
    self.report = report
  }

  deinit {}

  /// On `queue`: starts reading. `onTerminated` runs on `queue` once the connection is closed.
  func start(onTerminated: @escaping @Sendable () -> Void) {
    self.onTerminated = onTerminated
    let descriptor = fileDescriptor
    let channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue) { _ in
      Darwin.close(descriptor)
    }
    channel.setLimit(lowWater: 1)
    self.channel = channel
    channel.read(offset: 0, length: Int.max, queue: queue) { [self] done, data, error in
      received(done: done, data: data, error: error)
    }
    queue.asyncAfter(deadline: .now() + Self.headerTimeout) { [weak self] in
      guard let self, case .header = phase else { return }
      closeNow()
    }
  }

  /// From the main actor, after the header was accepted.
  func activate() {
    queue.async { [self] in
      guard case .pending(let contentID, let buffered, let ended) = phase else { return }
      phase = .open(contentID: contentID)
      if !buffered.isEmpty {
        report(self, .input(contentID: contentID, bytes: buffered))
      }
      if ended { finish() }
    }
  }

  /// From the main actor: bytes for the terminal, in call order.
  func write(_ bytes: [UInt8]) {
    queue.async { [self] in
      guard case .open = phase, let channel else { return }
      let data = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
      channel.write(offset: 0, data: data, queue: queue) { [weak self] done, _, error in
        guard done, error != 0 else { return }
        self?.finish()
      }
    }
  }

  /// From the main actor: closes without reporting.
  func close() {
    queue.async { [self] in closeNow() }
  }

  /// On `queue`: closes without reporting. The peer reads EOF at once.
  func closeNow() {
    if case .closed = phase { return }
    phase = .closed
    Darwin.shutdown(fileDescriptor, SHUT_RDWR)
    channel?.close(flags: .stop)
    channel = nil
    let terminated = onTerminated
    onTerminated = nil
    terminated?()
  }

  /// On `queue`: closes and reports `.closed` for an open pipe.
  private func finish() {
    let reported: String?
    switch phase {
    case .open(let contentID): reported = contentID
    case .closed: return
    case .header, .pending: reported = nil
    }
    closeNow()
    if let reported { report(self, .closed(contentID: reported)) }
  }

  private func received(done: Bool, data: DispatchData?, error: Int32) {
    if let data, !data.isEmpty {
      consume([UInt8](data))
    }
    guard done else { return }
    switch phase {
    case .pending(let contentID, let buffered, _):
      phase = .pending(contentID: contentID, buffered: buffered, ended: true)
    case .header:
      closeNow()
    case .open:
      finish()
    case .closed:
      break
    }
  }

  private func consume(_ bytes: [UInt8]) {
    switch phase {
    case .header(let earlier):
      let line = earlier + bytes
      guard let newline = line.firstIndex(of: UInt8(ascii: "\n")) else {
        if line.count > Self.maximumHeaderLength {
          closeNow()
        } else {
          phase = .header(line)
        }
        return
      }
      guard newline <= Self.maximumHeaderLength,
        let text = String(validating: line[..<newline], as: UTF8.self),
        let header = RemotePipeProtocol.parseHeader(text)
      else {
        closeNow()
        return
      }
      phase = .pending(contentID: header.contentID, buffered: Array(line[(newline + 1)...]), ended: false)
      report(self, .header(token: header.token, contentID: header.contentID))
    case .pending(let contentID, let buffered, let ended):
      phase = .pending(contentID: contentID, buffered: buffered + bytes, ended: ended)
    case .open(let contentID):
      report(self, .input(contentID: contentID, bytes: bytes))
    case .closed:
      break
    }
  }
}
