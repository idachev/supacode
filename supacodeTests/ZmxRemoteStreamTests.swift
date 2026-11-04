import ConcurrencyExtras
import Darwin
import Foundation
import Testing

@testable import supacode

/// A one-client fake zmx daemon on a Unix socket: it records what the client
/// writes and replays scripted reply bytes once the client's first frame arrives.
nonisolated private final class FakeZmxDaemon: @unchecked Sendable {
  let path: String
  let received = LockIsolated<[UInt8]>([])
  /// Yields the running byte count after every read, so a test awaits bytes
  /// instead of sleeping.
  let receivedCounts: AsyncStream<Int>
  private let countContinuation: AsyncStream<Int>.Continuation
  private let listenFD: Int32
  private let clientFD = LockIsolated<Int32>(-1)

  init() throws {
    (receivedCounts, countContinuation) = AsyncStream.makeStream(of: Int.self)
    path = "/tmp/zrs-\(UUID().uuidString.prefix(8)).sock"
    listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { sun in
      bytes.withUnsafeBufferPointer { memcpy(sun, $0.baseAddress!, $0.count) }
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, length) }
    }
    guard bound == 0, listen(listenFD, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
  }

  deinit {
    close(listenFD)
    unlink(path)
  }

  /// Accepts one client, waits for `expectBytes` bytes from it, then writes `reply`.
  func serve(expectBytes: Int, reply: [UInt8]) {
    Thread { [self] in
      let descriptor = accept(listenFD, nil, nil)
      clientFD.setValue(descriptor)
      readAtLeast(descriptor: descriptor, count: expectBytes)
      _ = reply.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
      readAtLeast(descriptor: descriptor, count: .max)
      close(descriptor)
    }.start()
  }

  /// Writes more bytes to the accepted client (live output after the scripted reply).
  func write(_ bytes: [UInt8]) {
    let descriptor = clientFD.value
    _ = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
  }

  private func readAtLeast(descriptor: Int32, count: Int) {
    var buffer = [UInt8](repeating: 0, count: 4096)
    while received.value.count < count {
      let read = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
      guard read > 0 else { return }
      let chunk = Array(buffer[0..<read])
      let total = received.withValue { value -> Int in
        value.append(contentsOf: chunk)
        return value.count
      }
      countContinuation.yield(total)
    }
  }
}

nonisolated private func frame(tag: UInt8, _ payload: [UInt8]) -> [UInt8] {
  ZmxIPCFrameEncoder.frame(tag: tag, payload: payload)
}

struct ZmxRemoteStreamTests {
  @Test(.timeLimit(.minutes(1)))
  func relaysTheSnapshotThenLiveOutputAndWritesInputWithSend() async throws {
    let daemon = try FakeZmxDaemon()
    // Output broadcast before the Capture reply is already part of the
    // snapshot, so the stream must drop it.
    let reply =
      frame(tag: ZmxIPCTag.output, Array("early".utf8))
      + frame(tag: ZmxIPCFrameEncoder.captureTag, Array("SCREEN".utf8))
      // Two PTY chunks arrive together and are coalesced into one event.
      + frame(tag: ZmxIPCTag.output, Array("li".utf8))
      + frame(tag: ZmxIPCTag.output, Array("ve".utf8))
    daemon.serve(expectBytes: 16, reply: reply)

    let stream = ZmxRemoteStream(socketPath: daemon.path)
    stream.start(scrollbackRows: 500)
    var iterator = stream.events.makeAsyncIterator()
    #expect(await iterator.next() == .snapshot(Array("SCREEN".utf8)))
    #expect(await iterator.next() == .output(Array("live".utf8)))

    #expect(stream.send(Array("é\r".utf8)))
    let sent = Array("é\r".utf8)
    let expected =
      ZmxIPCFrameEncoder.capture(format: ZmxIPCFrameEncoder.formatVT, scrollbackRows: 500)
      + frame(tag: ZmxIPCFrameEncoder.sendTag, sent)
    for await count in daemon.receivedCounts where count >= expected.count { break }
    #expect(daemon.received.value == expected)
    stream.stop()
    #expect(await iterator.next() == nil)
  }

  /// A fresh session that never answers `Capture`: the stream asks again, then
  /// starts with the output it saw as the screen and relays live output, instead
  /// of dropping every frame while `Send` input still reaches the PTY.
  @Test(.timeLimit(.minutes(1)))
  func startsWithoutACaptureReplyAfterTheLastAttempt() async throws {
    let daemon = try FakeZmxDaemon()
    daemon.serve(expectBytes: 16, reply: frame(tag: ZmxIPCTag.output, Array("prompt$ ".utf8)))

    let stream = ZmxRemoteStream(socketPath: daemon.path, captureRetryMilliseconds: 250, captureAttempts: 2)
    stream.start(scrollbackRows: 500)
    var iterator = stream.events.makeAsyncIterator()
    #expect(await iterator.next() == .snapshot(Array("prompt$ ".utf8)))
    daemon.write(frame(tag: ZmxIPCTag.output, Array("ls\r\n".utf8)))
    #expect(await iterator.next() == .output(Array("ls\r\n".utf8)))

    let capture = ZmxIPCFrameEncoder.capture(format: ZmxIPCFrameEncoder.formatVT, scrollbackRows: 500)
    for await count in daemon.receivedCounts where count >= 2 * capture.count { break }
    #expect(daemon.received.value == capture + capture)
    stream.stop()
    #expect(await iterator.next() == nil)
  }

  /// Early output past the cap starts the stream at that frame: the snapshot
  /// and the live output after it are the byte stream with no gap. No deadline
  /// is involved (the retry interval is far beyond the test).
  @Test(.timeLimit(.minutes(1)))
  func earlyOutputPastTheCapStartsTheStreamWithoutAGap() async throws {
    let daemon = try FakeZmxDaemon()
    let reply =
      frame(tag: ZmxIPCTag.output, Array("abc".utf8))
      + frame(tag: ZmxIPCTag.output, Array("defgh".utf8))
      + frame(tag: ZmxIPCTag.output, Array("i".utf8))
    daemon.serve(expectBytes: 16, reply: reply)

    let stream = ZmxRemoteStream(
      socketPath: daemon.path, captureRetryMilliseconds: 60_000, captureAttempts: 1, earlyOutputLimit: 4)
    stream.start(scrollbackRows: 0)
    var iterator = stream.events.makeAsyncIterator()
    #expect(await iterator.next() == .snapshot(Array("abc".utf8)))
    var live: [UInt8] = []
    while live.count < 6, case .output(let bytes) = await iterator.next() { live += bytes }
    #expect(live == Array("defghi".utf8))
    stream.stop()
  }

  @Test func reportsAMissingSessionAsClosed() async {
    let stream = ZmxRemoteStream(socketPath: "/tmp/zrs-missing-\(UUID().uuidString.prefix(8)).sock")
    stream.start(scrollbackRows: 0)
    var iterator = stream.events.makeAsyncIterator()
    #expect(await iterator.next() == .closed(reason: "session not running"))
    #expect(await iterator.next() == nil)
  }

  @Test func socketPathUsesTheSupacodeSessionName() {
    let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!
    #expect(ZmxRemoteStream.socketPath(contentID: id).hasSuffix("/supa-00000000-0000-0000-0000-0000000000ab"))
  }
}
