import ConcurrencyExtras
import Darwin
import Foundation
import SupacodeSettingsShared

nonisolated private let remoteStreamLogger = SupaLogger("RemoteAccess")

/// zmx IPC frames the remote stream writes. The wire header is 8 bytes: tag,
/// little-endian `u32` length, 3 bytes padding (`ThirdParty/zmx/src/ipc.zig`).
nonisolated enum ZmxIPCFrameEncoder {
  static let infoTag: UInt8 = 6
  static let sendTag: UInt8 = 18
  static let captureTag: UInt8 = 22
  /// `util.HistoryFormat` raw values.
  static let formatPlain: UInt8 = 0
  static let formatVT: UInt8 = 1

  static func frame(tag: UInt8, payload: [UInt8]) -> [UInt8] {
    var bytes: [UInt8] = [tag]
    bytes.append(contentsOf: littleEndian(UInt32(payload.count)))
    bytes.append(contentsOf: [0, 0, 0])
    bytes.append(contentsOf: payload)
    return bytes
  }

  /// `ipc.Capture` is a packed `{ format: u8, rows: u32 }`: a 40-bit integer
  /// that occupies 8 bytes on the wire.
  static func capture(format: UInt8, scrollbackRows: UInt32) -> [UInt8] {
    var payload: [UInt8] = [format]
    payload.append(contentsOf: littleEndian(scrollbackRows))
    payload.append(contentsOf: [0, 0, 0])
    return frame(tag: captureTag, payload: payload)
  }

  /// `ipc.Info` is an extern struct: `clients_len: u64`, then `pid: i32` at offset 8.
  static func infoPID(_ payload: [UInt8]) -> Int32? {
    guard payload.count >= 12 else { return nil }
    let raw = UInt32(payload[8]) | UInt32(payload[9]) << 8 | UInt32(payload[10]) << 16 | UInt32(payload[11]) << 24
    return Int32(bitPattern: raw)
  }

  private static func littleEndian(_ value: UInt32) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
  }
}

/// A passive client of one zmx session socket. It never sends `Init`, `Input`
/// or `Resize`, so it never becomes the session leader and never resizes the
/// PTY: it asks for a `Capture` of the current screen, then relays broadcast
/// `Output`, and writes input with `Send`, which zmx queues without changing
/// leadership.
nonisolated final class ZmxRemoteStream: @unchecked Sendable {
  enum Event: Equatable, Sendable {
    /// The current screen (VT) plus the requested scrollback, sent once first.
    case snapshot([UInt8])
    /// Live PTY output after the snapshot, in order.
    case output([UInt8])
    case closed(reason: String)
  }

  let events: AsyncStream<Event>
  private let continuation: AsyncStream<Event>.Continuation
  private let socketPath: String
  private let socketFD = LockIsolated<Int32>(-1)
  private let stopped = LockIsolated(false)
  private let writeLock = NSLock()
  private let captureRetryMilliseconds: Int
  private let captureAttempts: Int
  private let earlyOutputLimit: Int

  /// `captureRetryMilliseconds` and `captureAttempts` bound the wait for the
  /// `Capture` reply: it is asked again after each interval, and after the last
  /// attempt the stream starts without it (see `readLoop`).
  init(
    socketPath: String,
    captureRetryMilliseconds: Int = ZmxRemoteStream.captureRetryMilliseconds,
    captureAttempts: Int = ZmxRemoteStream.captureAttempts,
    earlyOutputLimit: Int = ZmxRemoteStream.earlyOutputLimit
  ) {
    self.socketPath = socketPath
    self.captureRetryMilliseconds = max(1, captureRetryMilliseconds)
    self.captureAttempts = max(1, captureAttempts)
    self.earlyOutputLimit = max(0, earlyOutputLimit)
    (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
  }

  deinit {
    stop()
  }

  /// The zmx socket of a Supacode content, in the socket dir the app uses.
  static func socketPath(contentID: UUID) -> String {
    let dir = ZmxSocketBudget.socketDir()
    let separator = dir.hasSuffix("/") ? "" : "/"
    return dir + separator + ZmxSessionID.make(surfaceID: contentID)
  }

  /// Connects, requests the screen with up to `scrollbackRows` rows of history,
  /// and starts relaying on a dedicated thread.
  func start(scrollbackRows: Int) {
    guard let descriptor = Self.connect(to: socketPath) else {
      finish(reason: "session not running")
      return
    }
    socketFD.setValue(descriptor)
    let rows = UInt32(clamping: max(0, scrollbackRows))
    let capture = ZmxIPCFrameEncoder.capture(format: ZmxIPCFrameEncoder.formatVT, scrollbackRows: rows)
    guard write(capture) else {
      finish(reason: "session closed")
      closeSocket()
      return
    }
    let thread = Thread { [self] in readLoop(descriptor: descriptor, capture: capture) }
    thread.name = "supacode.remote-stream"
    thread.start()
  }

  /// Writes raw bytes to the PTY through `Send`, in chunks the daemon reads in one go.
  @discardableResult
  func send(_ bytes: [UInt8]) -> Bool {
    guard !bytes.isEmpty else { return true }
    for start in stride(from: 0, to: bytes.count, by: 4096) {
      let chunk = Array(bytes[start..<min(start + 4096, bytes.count)])
      guard write(ZmxIPCFrameEncoder.frame(tag: ZmxIPCFrameEncoder.sendTag, payload: chunk)) else { return false }
    }
    return true
  }

  func stop() {
    let alreadyStopped = stopped.withValue { value -> Bool in
      defer { value = true }
      return value
    }
    guard !alreadyStopped else { return }
    // shutdown() wakes the reader's poll(); the reader thread owns close(), so
    // the descriptor is never closed under a read in flight. The write lock
    // keeps the reader from closing (and the kernel from reusing) it between
    // the read and the shutdown.
    writeLock.lock()
    let descriptor = socketFD.value
    if descriptor >= 0 { Darwin.shutdown(descriptor, SHUT_RDWR) }
    writeLock.unlock()
    continuation.finish()
  }

  private func closeSocket() {
    writeLock.lock()
    defer { writeLock.unlock() }
    let descriptor = socketFD.withValue { value -> Int32 in
      defer { value = -1 }
      return value
    }
    if descriptor >= 0 { Darwin.close(descriptor) }
  }

  private func finish(reason: String) {
    guard !stopped.value else { return }
    continuation.yield(.closed(reason: reason))
    stop()
  }

  private func write(_ bytes: [UInt8]) -> Bool {
    writeLock.lock()
    defer { writeLock.unlock() }
    let descriptor = socketFD.value
    guard descriptor >= 0 else { return false }
    var offset = 0
    while offset < bytes.count {
      let written = bytes[offset...].withUnsafeBytes { raw in
        Darwin.write(descriptor, raw.baseAddress, raw.count)
      }
      if written < 0 {
        if errno == EINTR { continue }
        remoteStreamLogger.warning("zmx remote write failed: errno \(errno)")
        return false
      }
      offset += written
    }
    return true
  }

  /// Output waits this long for more bytes before it is yielded: a TUI redraw
  /// arrives as many tiny PTY chunks, and one relay message per chunk would
  /// multiply the WebSocket traffic (a 50 000-line `seq` gave 17 686 frames).
  static let coalesceMilliseconds: Int32 = 8
  static let coalesceLimit = 64 * 1024
  /// How long the stream waits for a `Capture` reply before it asks again.
  static let captureRetryMilliseconds = 1000
  /// `Capture` requests sent before the stream starts without a reply.
  static let captureAttempts = 3
  /// Output kept while the `Capture` reply is outstanding, for the fallback
  /// snapshot. A frame that would pass it starts the stream at once.
  static let earlyOutputLimit = 1 << 20

  private func readLoop(descriptor: Int32, capture: [UInt8]) {
    defer { closeSocket() }
    var decoder = ZmxIPCFrameDecoder(maxPayloadSize: 32 << 20)
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    // Output broadcast before the Capture reply is already in the snapshot.
    var gotSnapshot = false
    var pending: [UInt8] = []
    // A session that never answers `Capture` (a fresh one that is still
    // starting) must not silence the stream for good while `Send` input still
    // works: the request is repeated, and after the last attempt the output
    // seen so far becomes the snapshot and live output flows.
    var early: [UInt8] = []
    var attempts = 1
    var captureDeadline = Self.uptimeMilliseconds() + UInt64(captureRetryMilliseconds)
    // The fallback snapshot plus the live output after it is the PTY byte
    // stream with no gap, so no escape sequence is ever cut in two.
    func startWithoutCapture() {
      gotSnapshot = true
      continuation.yield(.snapshot(early))
      early = []
    }
    func checkCapture() -> Bool {
      guard !gotSnapshot, Self.uptimeMilliseconds() >= captureDeadline else { return true }
      if attempts < captureAttempts {
        attempts += 1
        captureDeadline = Self.uptimeMilliseconds() + UInt64(captureRetryMilliseconds)
        remoteStreamLogger.warning("zmx remote stream: no Capture reply yet, asking again (\(attempts))")
        return write(capture)
      }
      remoteStreamLogger.warning("zmx remote stream: no Capture reply, starting without the screen")
      startWithoutCapture()
      return true
    }
    func flush() {
      guard !pending.isEmpty else { return }
      continuation.yield(.output(pending))
      pending.removeAll(keepingCapacity: true)
    }
    func end(_ reason: String) {
      flush()
      finish(reason: reason)
    }
    func handle(_ frame: ZmxIPCFrame) {
      switch frame.tag {
      case ZmxIPCFrameEncoder.captureTag where !gotSnapshot:
        gotSnapshot = true
        early = []
        continuation.yield(.snapshot(frame.payload))
      case ZmxIPCTag.output where !gotSnapshot && early.count + frame.payload.count <= earlyOutputLimit:
        early.append(contentsOf: frame.payload)
      case ZmxIPCTag.output:
        if !gotSnapshot {
          remoteStreamLogger.warning("zmx remote stream: no Capture reply and the early output is full, starting")
          startWithoutCapture()
        }
        pending.append(contentsOf: frame.payload)
        if pending.count >= Self.coalesceLimit { flush() }
      default:
        break
      }
    }
    while !stopped.value {
      guard checkCapture() else {
        end("session closed")
        return
      }
      var pollFD = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let idleTimeout: Int32 = gotSnapshot ? 500 : Int32(clamping: min(captureRetryMilliseconds, 500))
      let ready = poll(&pollFD, 1, pending.isEmpty ? idleTimeout : Self.coalesceMilliseconds)
      if ready < 0 {
        if errno == EINTR { continue }
        end("session read failed")
        return
      }
      guard ready > 0 else {
        flush()
        continue
      }
      let count = buffer.withUnsafeMutableBytes { raw in Darwin.read(descriptor, raw.baseAddress, raw.count) }
      if count < 0 {
        if errno == EINTR || errno == EAGAIN { continue }
        end(stopped.value ? "detached" : "session read failed")
        return
      }
      if count == 0 {
        end("session ended")
        return
      }
      let frames: [ZmxIPCFrame]
      do {
        frames = try decoder.decode(Array(buffer[0..<count]))
      } catch {
        remoteStreamLogger.warning("zmx remote stream desynced: \(error)")
        end("session stream desynced")
        return
      }
      for frame in frames { handle(frame) }
    }
  }

  private static func uptimeMilliseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds / 1_000_000
  }

  /// One-shot `Capture` over a fresh passive connection; nil when the session
  /// is gone or does not answer within `timeoutMilliseconds`. Blocking: call it
  /// off the main actor.
  static func captureOnce(
    socketPath: String,
    format: UInt8,
    scrollbackRows: Int,
    timeoutMilliseconds: Int32 = 3000
  ) -> [UInt8]? {
    let request = ZmxIPCFrameEncoder.capture(format: format, scrollbackRows: UInt32(clamping: max(0, scrollbackRows)))
    return requestOnce(
      socketPath: socketPath, request: request, replyTag: ZmxIPCFrameEncoder.captureTag,
      timeoutMilliseconds: timeoutMilliseconds)
  }

  /// The session PTY's real size, read from its terminal device: zmx's `Info`
  /// reply names the shell pid, whose controlling tty is the PTY. This is the
  /// size every program in the session renders at, whatever the app's view
  /// reports. nil when the session is gone or the device cannot be read.
  /// Blocking: call it off the main actor.
  static func ptySize(socketPath: String) -> (columns: Int, rows: Int)? {
    guard
      let info = requestOnce(
        socketPath: socketPath, request: ZmxIPCFrameEncoder.frame(tag: ZmxIPCFrameEncoder.infoTag, payload: []),
        replyTag: ZmxIPCFrameEncoder.infoTag, timeoutMilliseconds: 1500),
      let pid = ZmxIPCFrameEncoder.infoPID(info), pid > 0
    else { return nil }
    var bsdInfo = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, size) == size,
      bsdInfo.e_tdev != UInt32.max, let name = devname(dev_t(bitPattern: bsdInfo.e_tdev), S_IFCHR)
    else { return nil }
    let device = open("/dev/" + String(cString: name), O_RDONLY | O_NOCTTY | O_NONBLOCK)
    guard device >= 0 else { return nil }
    defer { Darwin.close(device) }
    var window = winsize()
    guard ioctl(device, TIOCGWINSZ, &window) == 0, window.ws_col > 0, window.ws_row > 0 else { return nil }
    return (Int(window.ws_col), Int(window.ws_row))
  }

  /// Sends one request frame over a fresh passive connection and returns the
  /// payload of the first reply frame with `replyTag`.
  private static func requestOnce(
    socketPath: String,
    request: [UInt8],
    replyTag: UInt8,
    timeoutMilliseconds: Int32
  ) -> [UInt8]? {
    guard let descriptor = connect(to: socketPath) else { return nil }
    defer { Darwin.close(descriptor) }
    let written = request.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    guard written == request.count else { return nil }
    var decoder = ZmxIPCFrameDecoder(maxPayloadSize: 32 << 20)
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
      var pollFD = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let ready = poll(&pollFD, 1, 200)
      if ready < 0, errno != EINTR { return nil }
      guard ready > 0 else { continue }
      let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
      guard count > 0 else { return nil }
      guard let frames = try? decoder.decode(Array(buffer[0..<count])) else { return nil }
      if let reply = frames.first(where: { $0.tag == replyTag }) {
        return reply.payload
      }
    }
    return nil
  }

  private static func connect(to path: String) -> Int32? {
    var lastErrno: Int32 = 0
    return ZmxSessionWatcher.connect(to: path, lastConnectErrno: &lastErrno)
  }
}
