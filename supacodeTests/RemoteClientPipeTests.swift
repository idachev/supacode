import Darwin
import Foundation
import Testing

@testable import supacode

/// The pipe server over real unix-socket connections. The test is the CLI: it connects to
/// `server.socketPath`, sends the header and reads with a timeout off the main actor (the server
/// validates tokens on the main actor, so a blocking read here would deadlock).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteClientPipeTests {
  nonisolated static let wait: TimeInterval = 10

  @Test func theHeaderRoundTrips() {
    let line = String(bytes: RemotePipeProtocol.header(token: "tok", contentID: "C1"), encoding: .utf8)
    #expect(line == "SUPACODE-PIPE 1 tok C1\n")
    #expect(RemotePipeProtocol.parseHeader("SUPACODE-PIPE 1 tok C1")?.contentID == "C1")
    #expect(RemotePipeProtocol.parseHeader("SUPACODE-PIPE 1 tok C1")?.token == "tok")
    for bad in ["", "SUPACODE-PIPE 2 tok C1", "PIPE 1 tok C1", "SUPACODE-PIPE 1 tok", "SUPACODE-PIPE 1 tok C1 extra"] {
      #expect(RemotePipeProtocol.parseHeader(bad) == nil)
    }
  }

  @Test func aPipeWithTheRightTokenCarriesBytesBothWays() async throws {
    let fixture = try Fixture()
    defer { fixture.tearDown() }
    let token = fixture.server.expect(contentID: "C1")

    let client = try PipeClient(path: fixture.server.socketPath)
    defer { client.close() }
    client.send(RemotePipeProtocol.header(token: token, contentID: "C1") + Array("ls\r".utf8))

    #expect(await fixture.recorder.waitFor { $0.contains("input C1 ls\r") })
    #expect(fixture.recorder.events == ["opened C1", "input C1 ls\r"])

    fixture.server.write(contentID: "C1", Array("out".utf8))
    #expect(await client.read(count: 3) == .bytes(Array("out".utf8)))

    client.close()
    #expect(await fixture.recorder.waitFor { $0.contains("closed C1") })
    #expect(fixture.recorder.events == ["opened C1", "input C1 ls\r", "closed C1"])
  }

  @Test func aWriteFromOnOpenedReachesTheClient() async throws {
    let fixture = try Fixture()
    defer { fixture.tearDown() }
    let server = fixture.server
    server.onOpened = { server.write(contentID: $0, Array("first screen".utf8)) }
    let token = server.expect(contentID: "C1")

    let client = try PipeClient(path: server.socketPath)
    defer { client.close() }
    client.send(RemotePipeProtocol.header(token: token, contentID: "C1"))
    #expect(await client.read(count: 12) == .bytes(Array("first screen".utf8)))
  }

  @Test func aWrongTokenIsClosedAndReportsNothing() async throws {
    let fixture = try Fixture()
    defer { fixture.tearDown() }
    let token = fixture.server.expect(contentID: "C1")

    let wrong = try PipeClient(path: fixture.server.socketPath)
    defer { wrong.close() }
    wrong.send(RemotePipeProtocol.header(token: "not-\(token)", contentID: "C1") + Array("x".utf8))
    #expect(await wrong.read(count: 1) == .eof)

    let garbage = try PipeClient(path: fixture.server.socketPath)
    defer { garbage.close() }
    garbage.send(Array("hello there\n".utf8))
    #expect(await garbage.read(count: 1) == .eof)

    // The right token still works, so the only report is that pipe's.
    let right = try PipeClient(path: fixture.server.socketPath)
    defer { right.close() }
    right.send(RemotePipeProtocol.header(token: token, contentID: "C1"))
    #expect(await fixture.recorder.waitFor { $0.contains("opened C1") })
    #expect(fixture.recorder.events == ["opened C1"])
  }

  @Test func aTokenWorksOnce() async throws {
    let fixture = try Fixture()
    defer { fixture.tearDown() }
    let token = fixture.server.expect(contentID: "C1")

    let first = try PipeClient(path: fixture.server.socketPath)
    first.send(RemotePipeProtocol.header(token: token, contentID: "C1"))
    #expect(await fixture.recorder.waitFor { $0.contains("opened C1") })
    first.close()
    #expect(await fixture.recorder.waitFor { $0.contains("closed C1") })

    let second = try PipeClient(path: fixture.server.socketPath)
    defer { second.close() }
    second.send(RemotePipeProtocol.header(token: token, contentID: "C1"))
    #expect(await second.read(count: 1) == .eof)

    let fresh = fixture.server.expect(contentID: "C1")
    let third = try PipeClient(path: fixture.server.socketPath)
    defer { third.close() }
    third.send(RemotePipeProtocol.header(token: fresh, contentID: "C1"))
    #expect(await fixture.recorder.waitFor { $0.count == 3 })
    #expect(fixture.recorder.events == ["opened C1", "closed C1", "opened C1"])
  }

  @Test func theSocketFileIsPrivate() throws {
    let fixture = try Fixture()
    defer { fixture.tearDown() }
    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.server.socketPath)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(attributes[.type] as? FileAttributeType == .typeSocket)
    #expect(fixture.server.socketPath.hasSuffix("/remote-pipe-\(ProcessInfo.processInfo.processIdentifier).sock"))
  }

  @Test func writesBeforeThePipeOpensAreDropped() async throws {
    let fixture = try Fixture()
    defer { fixture.tearDown() }
    let token = fixture.server.expect(contentID: "C1")
    fixture.server.write(contentID: "C1", Array("early".utf8))

    let client = try PipeClient(path: fixture.server.socketPath)
    defer { client.close() }
    client.send(RemotePipeProtocol.header(token: token, contentID: "C1"))
    #expect(await fixture.recorder.waitFor { $0.contains("opened C1") })

    fixture.server.write(contentID: "C1", Array("late".utf8))
    #expect(await client.read(count: 4) == .bytes(Array("late".utf8)))
  }

  @Test func aSecondPipeForTheSameContentIsClosed() async throws {
    let fixture = try Fixture()
    defer { fixture.tearDown() }
    let token = fixture.server.expect(contentID: "C1")

    let first = try PipeClient(path: fixture.server.socketPath)
    defer { first.close() }
    first.send(RemotePipeProtocol.header(token: token, contentID: "C1"))
    #expect(await fixture.recorder.waitFor { $0.contains("opened C1") })

    let fresh = fixture.server.expect(contentID: "C1")
    let second = try PipeClient(path: fixture.server.socketPath)
    defer { second.close() }
    second.send(RemotePipeProtocol.header(token: fresh, contentID: "C1"))
    #expect(await second.read(count: 1) == .eof)

    // The first pipe is untouched.
    fixture.server.write(contentID: "C1", Array("still".utf8))
    #expect(await first.read(count: 5) == .bytes(Array("still".utf8)))
    #expect(fixture.recorder.events == ["opened C1"])
  }

  @Test func forgetClosesTheOpenPipeAndDropsTheToken() async throws {
    let fixture = try Fixture()
    defer { fixture.tearDown() }
    let token = fixture.server.expect(contentID: "C1")
    let other = fixture.server.expect(contentID: "C2")

    let client = try PipeClient(path: fixture.server.socketPath)
    defer { client.close() }
    client.send(RemotePipeProtocol.header(token: token, contentID: "C1"))
    #expect(await fixture.recorder.waitFor { $0.contains("opened C1") })

    fixture.server.forget(contentID: "C1")
    #expect(fixture.recorder.events == ["opened C1", "closed C1"])
    #expect(await client.read(count: 1) == .eof)

    fixture.server.forget(contentID: "C2")
    let late = try PipeClient(path: fixture.server.socketPath)
    defer { late.close() }
    late.send(RemotePipeProtocol.header(token: other, contentID: "C2"))
    #expect(await late.read(count: 1) == .eof)
    #expect(fixture.recorder.events == ["opened C1", "closed C1"])
  }

  @Test func stopClosesEveryPipeAndRemovesTheSocket() async throws {
    let fixture = try Fixture()
    defer { fixture.tearDown() }
    let token = fixture.server.expect(contentID: "C1")

    let client = try PipeClient(path: fixture.server.socketPath)
    defer { client.close() }
    client.send(RemotePipeProtocol.header(token: token, contentID: "C1"))
    #expect(await fixture.recorder.waitFor { $0.contains("opened C1") })

    fixture.server.stop()
    #expect(fixture.recorder.events == ["opened C1", "closed C1"])
    #expect(await client.read(count: 1) == .eof)
    #expect(!FileManager.default.fileExists(atPath: fixture.server.socketPath))
  }

  @Test func releasingAStartedServerRemovesTheSocket() throws {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appending(path: "scp-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    var server: RemotePipeServer? = RemotePipeServer(directory: directory)
    try server?.start()
    let path = try #require(server?.socketPath)
    #expect(FileManager.default.fileExists(atPath: path))
    server = nil
    #expect(!FileManager.default.fileExists(atPath: path))
  }
}

extension RemoteClientPipeTests {
  /// A started server in a fresh short directory (`sun_path` is 104 bytes) with its callbacks
  /// recorded as strings.
  @MainActor
  struct Fixture {
    let directory: URL
    let server: RemotePipeServer
    let recorder = Recorder()

    init() throws {
      let name = "scp-\(UUID().uuidString.prefix(8))"
      directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appending(path: name, directoryHint: .isDirectory)
      server = RemotePipeServer(directory: directory)
      let recorder = recorder
      server.onOpened = { recorder.events.append("opened \($0)") }
      server.onInput = { recorder.events.append("input \($0) \(String(bytes: $1, encoding: .utf8) ?? "<not utf8>")") }
      server.onClosed = { recorder.events.append("closed \($0)") }
      try server.start()
    }

    func tearDown() {
      server.stop()
      try? FileManager.default.removeItem(at: directory)
    }
  }

  @MainActor
  final class Recorder {
    var events: [String] = []

    nonisolated deinit {}

    /// Lets queued main-actor work run until `condition` holds or the deadline passes.
    func waitFor(_ condition: ([String]) -> Bool) async -> Bool {
      let deadline = Date.now.addingTimeInterval(RemoteClientPipeTests.wait)
      while !condition(events) {
        guard Date.now < deadline else { return false }
        await Task.yield()
      }
      return true
    }
  }

  nonisolated enum ReadResult: Equatable, Sendable {
    case bytes([UInt8])
    case eof
    case timedOut
    case failed(Int32)
  }

  /// A blocking unix-socket client; reads run on a global queue behind a continuation.
  nonisolated final class PipeClient: Sendable {
    let fileDescriptor: Int32

    init(path: String) throws {
      let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
      guard socketFD >= 0 else { throw POSIXError(.EBADF) }
      var addr = sockaddr_un()
      addr.sun_family = sa_family_t(AF_UNIX)
      let pathBytes = path.utf8CString
      _ = withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
        pathBytes.withUnsafeBufferPointer { memcpy(sunPath, $0.baseAddress!, $0.count) }
      }
      let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
      let result = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socketFD, $0, addrLen) }
      }
      guard result == 0 else {
        Darwin.close(socketFD)
        throw POSIXError(.ECONNREFUSED)
      }
      var enabled: Int32 = 1
      _ = setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
      var timeout = timeval(tv_sec: Int(RemoteClientPipeTests.wait), tv_usec: 0)
      _ = setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      fileDescriptor = socketFD
    }

    deinit {
      Darwin.close(fileDescriptor)
    }

    func send(_ bytes: [UInt8]) {
      _ = bytes.withUnsafeBytes { Darwin.write(fileDescriptor, $0.baseAddress, $0.count) }
    }

    /// Closes this side; the server sees EOF. Safe to call twice.
    func close() {
      Darwin.shutdown(fileDescriptor, SHUT_RDWR)
    }

    /// Reads until `count` bytes arrived (`.bytes`), the server closed first (`.eof`, even after
    /// some bytes), or the receive timeout passed.
    func read(count: Int) async -> ReadResult {
      let socketFD = fileDescriptor
      return await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
          var collected: [UInt8] = []
          var buffer = [UInt8](repeating: 0, count: 4096)
          while collected.count < count {
            let got = buffer.withUnsafeMutableBytes { Darwin.read(socketFD, $0.baseAddress, $0.count) }
            if got == 0 { return continuation.resume(returning: .eof) }
            if got < 0 {
              let code = errno
              if code == EINTR { continue }
              return continuation.resume(returning: code == EAGAIN ? .timedOut : .failed(code))
            }
            collected += buffer[0..<got]
          }
          continuation.resume(returning: .bytes(collected))
        }
      }
    }
  }
}
