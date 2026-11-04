import Darwin
import Foundation
import Network
import Security
import SupacodeSettingsShared

nonisolated private let lanLogger = SupaLogger("RemoteAccess")

/// The Mac's end of the LAN shortcut: a TLS 1.3 WebSocket listener for phones
/// on the same network. The phone pins the certificate (`RemoteLANIdentity`)
/// and must send the client key in `Authorization`. Any source address is
/// accepted; the pin, the key, `maxPeers` and the 10 s handshake limit protect it.
@MainActor
final class RemoteLANServer {
  static let maxPeers = 8
  /// Response header only an upgrade with the right key gets.
  nonisolated static let acceptedMarker = (name: "X-Supacode-LAN", value: "1")

  /// The router's view of one authenticated phone.
  struct Callbacks {
    let opened: (_ connID: String, _ send: @escaping (String) -> Void) -> Void
    let received: (_ connID: String, _ text: String) -> Void
    let closed: (_ connID: String) -> Void
  }

  let fingerprint: String
  private let identity: SecIdentity
  private let clientKey: String
  private let callbacks: Callbacks
  private let queue = DispatchQueue(label: "supacode.remote-lan")
  private var listener: NWListener?
  private var peers: [String: LANPeer] = [:]
  private var nextPeer = 0
  private(set) var port: UInt16?
  private var readyWaiters: [CheckedContinuation<UInt16?, Never>] = []

  init(identity: RemoteLANIdentity.Loaded, clientKey: String, callbacks: Callbacks) {
    self.identity = identity.identity
    self.fingerprint = identity.fingerprint
    self.clientKey = clientKey
    self.callbacks = callbacks
  }

  nonisolated deinit {}

  func start() {
    guard let secIdentity = sec_identity_create(identity) else {
      lanLogger.warning("LAN shortcut: no usable TLS identity")
      return
    }
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
    let parameters = NWParameters(tls: tls)
    parameters.prohibitedInterfaceTypes = [.cellular]
    let webSocket = NWProtocolWebSocket.Options()
    webSocket.autoReplyPing = true
    webSocket.maximumMessageSize = 32 << 20
    let expected = Data("Bearer \(clientKey)".utf8)
    webSocket.setClientRequestHandler(queue) { _, headers in
      let presented = headers.first { $0.name.caseInsensitiveCompare("Authorization") == .orderedSame }?.value
      let accepted = Self.constantTimeEqual(Data((presented ?? "").utf8), expected)
      // `.reject` alone leaves the connection `.ready` without a response, so the
      // accepted upgrade carries a marker that `LANPeer` checks before it opens.
      return accepted
        ? NWProtocolWebSocket.Response(status: .accept, subprotocol: nil, additionalHeaders: [Self.acceptedMarker])
        : NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
    }
    parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
    do {
      let listener = try NWListener(using: parameters, on: .any)
      listener.stateUpdateHandler = { [weak self] state in
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.listenerChanged(state) } }
      }
      listener.newConnectionHandler = { [weak self] connection in
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.accept(connection) } }
      }
      listener.start(queue: queue)
      self.listener = listener
    } catch {
      lanLogger.warning("LAN shortcut listener failed: \(error)")
    }
  }

  /// The listening port once the listener is ready, or nil when it failed.
  func waitUntilReady() async -> UInt16? {
    if let port { return port }
    if listener == nil { return nil }
    return await withCheckedContinuation { readyWaiters.append($0) }
  }

  func stop() {
    listener?.cancel()
    listener = nil
    port = nil
    resumeWaiters()
    for peer in peers.values { peer.close() }
    peers.removeAll()
  }

  private func resumeWaiters() {
    let waiters = readyWaiters
    readyWaiters.removeAll()
    for waiter in waiters { waiter.resume(returning: port) }
  }

  private func listenerChanged(_ state: NWListener.State) {
    switch state {
    case .ready:
      port = listener?.port?.rawValue
      lanLogger.info("LAN shortcut listening on port \(port.map(String.init) ?? "?")")
    case .failed(let error):
      lanLogger.warning("LAN shortcut listener stopped: \(error)")
      port = nil
    case .cancelled:
      port = nil
    default:
      return
    }
    resumeWaiters()
  }

  private func accept(_ connection: NWConnection) {
    guard peers.count < Self.maxPeers else {
      lanLogger.info("LAN shortcut: refused \(connection.endpoint): too many peers (\(Self.maxPeers))")
      connection.cancel()
      return
    }
    nextPeer += 1
    let connID = "lan-\(nextPeer)"
    let peer = LANPeer(
      connID: connID,
      connection: connection,
      queue: queue,
      onReady: { [weak self] peer in
        self?.callbacks.opened(peer.connID) { [weak peer] text in peer?.send(text) }
      },
      onText: { [weak self] connID, text in self?.callbacks.received(connID, text) },
      onClosed: { [weak self] peer in
        guard let self, self.peers.removeValue(forKey: peer.connID) != nil else { return }
        if peer.isReady { self.callbacks.closed(peer.connID) }
      }
    )
    peers[connID] = peer
    peer.start()
  }

  nonisolated static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    var difference = UInt8(truncatingIfNeeded: lhs.count ^ rhs.count)
    for index in 0..<max(lhs.count, rhs.count) {
      let left = index < lhs.count ? lhs[lhs.startIndex + index] : 0
      let right = index < rhs.count ? rhs[rhs.startIndex + index] : 0
      difference |= left ^ right
    }
    return difference == 0
  }

  /// Whether an interface's IPv4 address is offered to the phone: only physical
  /// Wi-Fi/Ethernet (`en*`; skips feth, utun, bridge, awdl, llw, vmnet), never
  /// link-local 169.254/16 or loopback 127/8.
  nonisolated static func isOfferable(interface: String, ipv4 bytes: [UInt8]) -> Bool {
    guard interface.hasPrefix("en"), bytes.count == 4 else { return false }
    return bytes[0] != 127 && !(bytes[0] == 169 && bytes[1] == 254)
  }

  /// The IPv4 addresses of the Mac's active `en*` interfaces, in interface order.
  nonisolated static func lanAddresses() -> [String] {
    var result: [String] = []
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
      defer { cursor = entry.pointee.ifa_next }
      let flags = Int32(entry.pointee.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
        let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET)
      else { continue }
      let bytes = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
        withUnsafeBytes(of: pointer.pointee.sin_addr) { [UInt8]($0) }
      }
      guard isOfferable(interface: String(cString: entry.pointee.ifa_name), ipv4: bytes) else { continue }
      let text = bytes.map(String.init).joined(separator: ".")
      if !result.contains(text) { result.append(text) }
    }
    return result
  }
}

/// One phone on the LAN after TLS and the key check: text messages both ways.
/// All state changes run on the main actor; the connection's callbacks hop there.
@MainActor
private final class LANPeer {
  /// A connection that has not finished TLS and the upgrade by then is closed,
  /// so stalled sockets cannot hold every peer slot.
  static let readyTimeout: TimeInterval = 10

  let connID: String
  private let connection: NWConnection
  private let queue: DispatchQueue
  private let onReady: (LANPeer) -> Void
  private let onText: (String, String) -> Void
  private let onClosed: (LANPeer) -> Void
  private(set) var isReady = false
  private var closed = false

  init(
    connID: String,
    connection: NWConnection,
    queue: DispatchQueue,
    onReady: @escaping (LANPeer) -> Void,
    onText: @escaping (String, String) -> Void,
    onClosed: @escaping (LANPeer) -> Void
  ) {
    self.connID = connID
    self.connection = connection
    self.queue = queue
    self.onReady = onReady
    self.onText = onText
    self.onClosed = onClosed
  }

  nonisolated deinit {}

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self else { return }
          switch state {
          case .ready:
            guard !self.isReady, !self.closed else { return }
            guard self.wasAccepted else {
              lanLogger.info("LAN shortcut: refused \(self.connection.endpoint): wrong key")
              self.close()
              return
            }
            self.isReady = true
            self.onReady(self)
            self.receive()
          case .failed, .cancelled:
            self.close()
          default:
            break
          }
        }
      }
    }
    connection.start(queue: queue)
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.readyTimeout) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.isReady, !self.closed else { return }
        lanLogger.info("LAN shortcut: closed \(self.connection.endpoint): not ready within \(Int(Self.readyTimeout)) s")
        self.close()
      }
    }
  }

  /// Whether the server answered this connection's upgrade with `.accept`.
  private var wasAccepted: Bool {
    let metadata = connection.metadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
    let marker = RemoteLANServer.acceptedMarker
    return metadata?.additionalServerHeaders?.contains { $0.0 == marker.name && $0.1 == marker.value } == true
  }

  func close() {
    guard !closed else { return }
    closed = true
    connection.cancel()
    onClosed(self)
  }

  func send(_ text: String) {
    guard isReady, !closed else { return }
    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
    let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
    connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
  }

  private func receive() {
    connection.receiveMessage { [weak self] data, context, _, error in
      let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
        as? NWProtocolWebSocket.Metadata)?.opcode
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, !self.closed else { return }
          if error != nil || opcode == .close {
            self.close()
            return
          }
          if opcode == .text, let data {
            let text = String(decoding: data, as: UTF8.self)  // swiftlint:disable:this optional_data_string_conversion
            if text == "ping" { self.send("pong") } else { self.onText(self.connID, text) }
          }
          if !self.closed { self.receive() }
        }
      }
    }
  }
}
