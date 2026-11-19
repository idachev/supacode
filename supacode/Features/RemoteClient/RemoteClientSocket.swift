import Foundation
import Network
import Security
import SupacodeSettingsShared
import Synchronization

nonisolated private let socketLogger = SupaLogger("RemoteClient")

// The client's two WebSockets: one to the Cloudflare relay and one pinned TLS socket to the
// host Mac's LAN shortcut. A socket only opens, sends text, delivers text and reports its close;
// the `ping` keepalive and reconnects belong to the connection that owns it.
//
// Mechanisms, settled by a spike (2026-11-19) against a `RemoteLANServer` and a raw 401 listener:
// - LAN: Network.framework (`NWConnection` + `NWProtocolWebSocket`, `Authorization` through
//   `setAdditionalHeaders`, TLS 1.3 minimum, `sec_protocol_options_set_verify_block` pinning the
//   leaf DER with `RemoteLANTrust.pinMatches`). It passed every case: the right pin and key reach
//   `.ready` with the `X-Supacode-LAN: 1` response header and `ping` gets `pong`; a wrong pin fails
//   in the verify block (the connection goes to `.waiting(-9808)` before any upgrade request is
//   sent); a wrong key never carries the marker (the server aborts, `.waiting(ECONNABORTED)`).
//   Failures land in `.waiting`, not `.failed`, so `.waiting` closes the socket. The LAN socket
//   cannot see an HTTP status: its reasons are short English words only.
// - Relay: `URLSessionWebSocketTask`. Network.framework reports a 401 upgrade answer only as
//   `.waiting(ECONNABORTED)`, while URLSession exposes `task.response.statusCode`, so a refused
//   relay upgrade closes with the status as plain digits (`"401"`, `"403"`).
// No reason or log line is ever built from an error object: URLSession errors carry the URL.

nonisolated enum RemoteClientSocketEvent: Equatable, Sendable {
  case opened
  case text(String)
  case closed(reason: String)
}

/// One WebSocket. `events` yields `.opened` at most once, then `.text` frames, then exactly one
/// `.closed`, and ends after it. `send` before `.opened` or after `.closed` is dropped.
/// `close()` is idempotent; releasing the last reference closes the socket too (`"released"`).
/// `.closed(reason:)` is the HTTP status as plain digits when the server
/// refused the upgrade with a status the socket can see (relay only), otherwise a short English
/// reason. A socket has no connect timeout of its own: an unreachable address waits for TCP's.
nonisolated protocol RemoteClientSocket: AnyObject, Sendable {
  var events: AsyncStream<RemoteClientSocketEvent> { get }
  func send(_ text: String)
  func close()
}

nonisolated struct RemoteClientSocketFactory: Sendable {
  /// wss (or ws) to the relay with `Authorization: Bearer <key>`.
  var relay: @Sendable (_ url: URL, _ key: String) -> any RemoteClientSocket
  /// wss://<addr>:<port>/lan, TLS 1.3 only, the leaf certificate pinned to `fp`, the key in `Authorization`.
  var lan: @Sendable (_ addr: String, _ port: Int, _ fp: String, _ key: String) -> any RemoteClientSocket

  static let live = RemoteClientSocketFactory(
    relay: { url, key in RemoteRelaySocket(url: url, key: key) },
    lan: { addr, port, pin, key in RemoteLANSocket(addr: addr, port: port, pin: pin, key: key) }
  )

  /// The largest message either socket accepts, as on the host's sockets.
  static let maximumMessageSize = 32 << 20
}

/// The once-guarded event state both sockets share: `.opened` once, `.text` only while open,
/// `.closed` exactly once and then the stream ends.
nonisolated final class RemoteClientSocketEvents: Sendable {
  private struct State {
    var isOpen = false
    var isClosed = false
  }

  let stream: AsyncStream<RemoteClientSocketEvent>
  private let continuation: AsyncStream<RemoteClientSocketEvent>.Continuation
  private let state = Mutex(State())

  init() {
    (stream, continuation) = AsyncStream.makeStream()
  }

  var isOpen: Bool { state.withLock { $0.isOpen && !$0.isClosed } }

  /// Yields `.opened` unless the socket already opened or closed.
  func open() {
    state.withLock { current in
      guard !current.isOpen, !current.isClosed else { return }
      current.isOpen = true
      continuation.yield(.opened)
    }
  }

  func text(_ text: String) {
    state.withLock { current in
      guard current.isOpen, !current.isClosed else { return }
      continuation.yield(.text(text))
    }
  }

  /// Yields `.closed` and ends the stream; true only for the first call.
  @discardableResult
  func close(reason: String) -> Bool {
    let first = state.withLock { current -> Bool in
      guard !current.isClosed else { return false }
      current.isClosed = true
      continuation.yield(.closed(reason: reason))
      return true
    }
    if first { continuation.finish() }
    return first
  }
}

// MARK: - LAN

/// The pinned TLS 1.3 WebSocket to the host Mac's LAN shortcut. `.opened` comes only after the
/// upgrade answer carried `RemoteLANServer.acceptedMarker`: the server's `.reject` of a wrong key
/// leaves the connection `.ready` without a response (`.agent-memory/nwwebsocket-reject-stays-ready.md`).
nonisolated final class RemoteLANSocket: RemoteClientSocket {
  /// Whether the verify block refused the leaf certificate; read when the handshake fails.
  private final class PinCheck: Sendable {
    let rejected = Mutex(false)
  }

  private let sink = RemoteClientSocketEvents()
  private let connection: NWConnection
  private let queue: DispatchQueue
  private let pinCheck: PinCheck

  var events: AsyncStream<RemoteClientSocketEvent> { sink.stream }

  init(addr: String, port: Int, pin: String, key: String) {
    let queue = DispatchQueue(label: "supacode.remote-client.lan")
    let pinCheck = PinCheck()
    self.queue = queue
    self.pinCheck = pinCheck
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
    // Set before the connection copies the parameters.
    sec_protocol_options_set_verify_block(
      tls.securityProtocolOptions,
      { _, trustRef, complete in
        let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
        let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        let matches = leaf.map { RemoteLANTrust.pinMatches(der: SecCertificateCopyData($0) as Data, fp: pin) } ?? false
        if !matches { pinCheck.rejected.withLock { $0 = true } }
        complete(matches)
      },
      queue
    )
    let parameters = NWParameters(tls: tls)
    let webSocket = NWProtocolWebSocket.Options()
    webSocket.autoReplyPing = true
    webSocket.maximumMessageSize = RemoteClientSocketFactory.maximumMessageSize
    webSocket.setAdditionalHeaders([(name: "Authorization", value: "Bearer \(key)")])
    parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
    let host = addr.contains(":") ? "[\(addr)]" : addr
    guard let url = URL(string: "wss://\(host):\(port)/lan") else {
      connection = NWConnection(host: "invalid.invalid", port: 1, using: parameters)
      sink.close(reason: "invalid address")
      return
    }
    connection = NWConnection(to: .url(url), using: parameters)
    connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
    connection.start(queue: queue)
  }

  deinit {
    connection.cancel()
    sink.close(reason: "released")
  }

  func send(_ text: String) {
    guard sink.isOpen else { return }
    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
    let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
    connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
  }

  func close() {
    finish(reason: "closed")
  }

  private func finish(reason: String) {
    guard sink.close(reason: reason) else { return }
    connection.cancel()
    socketLogger.debug("LAN socket closed: \(reason)")
  }

  private func stateChanged(_ state: NWConnection.State) {
    switch state {
    case .ready:
      guard wasAccepted else {
        finish(reason: "key refused")
        return
      }
      sink.open()
      receive()
    case .waiting, .failed:
      // A failed handshake parks the connection in `.waiting` to retry; the owner reconnects instead.
      finish(reason: pinCheck.rejected.withLock { $0 } ? "certificate pin mismatch" : "connection failed")
    case .cancelled:
      finish(reason: "closed")
    default:
      break
    }
  }

  /// Whether the host answered the upgrade with the accepted-key marker.
  private var wasAccepted: Bool {
    let metadata = connection.metadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
    let marker = RemoteLANServer.acceptedMarker
    return metadata?.additionalServerHeaders?.contains { $0.0 == marker.name && $0.1 == marker.value } == true
  }

  private func receive() {
    connection.receiveMessage { [weak self] data, context, _, error in
      guard let self else { return }
      let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
        as? NWProtocolWebSocket.Metadata)?.opcode
      if error != nil {
        finish(reason: "connection lost")
        return
      }
      switch opcode {
      case .close:
        finish(reason: "closed by host")
        return
      case .text:
        // A text frame is valid UTF-8 by the protocol; the decoder never fails on it.
        // swiftlint:disable:next optional_data_string_conversion
        if let data { sink.text(String(decoding: data, as: UTF8.self)) }
      case nil:
        // No frame and no error: the stream ended.
        finish(reason: "connection lost")
        return
      default:
        break
      }
      if sink.isOpen { receive() }
    }
  }
}

// MARK: - Relay

/// The WebSocket to the Cloudflare relay with the client key as a bearer token.
nonisolated final class RemoteRelaySocket: RemoteClientSocket {
  /// The session's delegate. The session retains it until invalidated, so it holds the socket
  /// weakly: a socket dropped without `close()` still deinits and closes its connection.
  private final class Delegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    private struct Owner {
      weak var socket: RemoteRelaySocket?
    }

    private let owner = Mutex(Owner())

    private var socket: RemoteRelaySocket? { owner.withLock { $0.socket } }

    func attach(_ socket: RemoteRelaySocket) {
      owner.withLock { $0.socket = socket }
    }

    func urlSession(
      _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol subprotocol: String?
    ) {
      socket?.opened(webSocketTask)
    }

    func urlSession(
      _ session: URLSession,
      webSocketTask: URLSessionWebSocketTask,
      didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
      reason: Data?
    ) {
      socket?.finish(reason: "closed by relay")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
      socket?.completed(task, failed: error != nil)
    }
  }

  private let sink = RemoteClientSocketEvents()
  private let session: URLSession
  private let task: URLSessionWebSocketTask

  var events: AsyncStream<RemoteClientSocketEvent> { sink.stream }

  init(url: URL, key: String) {
    var request = URLRequest(url: url)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    let delegate = Delegate()
    session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    task = session.webSocketTask(with: request)
    task.maximumMessageSize = RemoteClientSocketFactory.maximumMessageSize
    delegate.attach(self)
    task.resume()
  }

  deinit {
    finish(reason: "released")
  }

  func send(_ text: String) {
    guard sink.isOpen else { return }
    task.send(.string(text)) { error in
      if error != nil { socketLogger.debug("Relay socket send failed") }
    }
  }

  func close() {
    finish(reason: "closed")
  }

  private func finish(reason: String) {
    guard sink.close(reason: reason) else { return }
    task.cancel(with: .normalClosure, reason: nil)
    // Lets the close frame go out, then releases the delegate.
    session.finishTasksAndInvalidate()
    socketLogger.debug("Relay socket closed: \(reason)")
  }

  private func opened(_ task: URLSessionWebSocketTask) {
    sink.open()
    receive(task)
  }

  /// A refused upgrade closes with its HTTP status as plain digits.
  private func completed(_ task: URLSessionTask, failed: Bool) {
    if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 {
      finish(reason: String(status))
    } else {
      finish(reason: failed ? "connection failed" : "closed by relay")
    }
  }

  private func receive(_ task: URLSessionWebSocketTask) {
    task.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(.string(let text)):
        sink.text(text)
      case .success:
        break
      case .failure:
        finish(reason: "connection lost")
        return
      }
      if sink.isOpen { receive(task) }
    }
  }
}
