import Foundation
import Network
import Synchronization
import Testing

@testable import supacode

/// The client's sockets over real loopback connections: the LAN socket against the host's
/// `RemoteLANServer` with a fresh identity, the relay socket against a local plain WebSocket
/// listener. Every outcome is read from `events` with a bounded wait, never from send/receive.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteClientSocketTests {
  private static let key = "abcde-fghij-klmno-pqrst-uvwxy-z2345"
  nonisolated static let wait: TimeInterval = 10

  /// What `EventProbe.next(within:)` saw.
  nonisolated enum Next: Equatable, Sendable {
    case event(RemoteClientSocketEvent)
    case ended
    case timedOut
  }

  /// Buffers a socket's events so a test can take them one by one with a timeout.
  nonisolated final class EventProbe: Sendable {
    private struct State {
      var buffer: [Next] = []
      var waiter: CheckedContinuation<Next, Never>?
      var waiterID = 0
    }

    private let state = Mutex(State())

    init(_ socket: any RemoteClientSocket) {
      let events = socket.events
      Task { [self] in
        for await event in events { push(.event(event)) }
        push(.ended)
      }
    }

    private func push(_ item: Next) {
      let waiter = state.withLock { current -> CheckedContinuation<Next, Never>? in
        guard let waiter = current.waiter else {
          current.buffer.append(item)
          return nil
        }
        current.waiter = nil
        return waiter
      }
      waiter?.resume(returning: item)
    }

    /// The next buffered item, or `.timedOut` when none arrives within `seconds`.
    func next(within seconds: TimeInterval = RemoteClientSocketTests.wait) async -> Next {
      await withCheckedContinuation { continuation in
        let (ready, id) = state.withLock { current -> (Next?, Int) in
          if !current.buffer.isEmpty { return (current.buffer.removeFirst(), 0) }
          current.waiterID += 1
          current.waiter = continuation
          return (nil, current.waiterID)
        }
        if let ready {
          continuation.resume(returning: ready)
          return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
          let waiter = self.state.withLock { current -> CheckedContinuation<Next, Never>? in
            guard current.waiterID == id, let waiter = current.waiter else { return nil }
            current.waiter = nil
            return waiter
          }
          waiter?.resume(returning: .timedOut)
        }
      }
    }
  }

  /// A local stand-in for the relay: a plain WebSocket echo that records `Authorization`,
  /// or a raw HTTP listener that answers every upgrade with 401. `markerless` is a stand-in
  /// for the host instead: TLS 1.3 with the host's identity, accepting every upgrade without
  /// the `X-Supacode-LAN` marker.
  nonisolated final class TestRelay: Sendable {
    enum Mode {
      case echo
      case unauthorized
      case markerless(RemoteLANIdentity.Loaded)
    }

    private struct Ready {
      var port: UInt16?
      var settled = false
      var waiter: CheckedContinuation<UInt16?, Never>?
    }

    /// The `Authorization` header of every upgrade request the echo listener saw.
    nonisolated final class Authorizations: Sendable {
      let values = Mutex<[String]>([])
    }

    let authorizations: Authorizations
    private let listener: NWListener
    private let ready = Mutex(Ready())

    init(_ mode: Mode) throws {
      let queue = DispatchQueue(label: "supacode.tests.relay")
      let authorizations = Authorizations()
      self.authorizations = authorizations
      var parameters = NWParameters.tcp
      if case .markerless(let identity) = mode {
        let tls = NWProtocolTLS.Options()
        if let secIdentity = sec_identity_create(identity.identity) {
          sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        }
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        parameters = NWParameters(tls: tls)
      }
      if case .unauthorized = mode {} else {
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.setClientRequestHandler(queue) { _, headers in
          let value = headers.first { $0.name.caseInsensitiveCompare("Authorization") == .orderedSame }?.value
          authorizations.values.withLock { $0.append(value ?? "") }
          return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
      }
      listener = try NWListener(using: parameters, on: .any)
      listener.newConnectionHandler = { connection in
        connection.start(queue: queue)
        switch mode {
        case .echo, .markerless: Self.echo(connection)
        case .unauthorized: Self.refuse(connection)
        }
      }
      listener.stateUpdateHandler = { [weak self] state in
        switch state {
        case .ready: self?.settle(self?.listener.port?.rawValue)
        case .failed, .cancelled: self?.settle(nil)
        default: break
        }
      }
      listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    /// The listening port, or nil when the listener failed.
    func port() async -> UInt16? {
      await withCheckedContinuation { continuation in
        let known = ready.withLock { current -> UInt16?? in
          if current.settled { return .some(current.port) }
          current.waiter = continuation
          return .none
        }
        if let known { continuation.resume(returning: known) }
      }
    }

    private func settle(_ port: UInt16?) {
      let waiter = ready.withLock { current -> CheckedContinuation<UInt16?, Never>? in
        guard !current.settled else { return nil }
        current.settled = true
        current.port = port
        defer { current.waiter = nil }
        return current.waiter
      }
      waiter?.resume(returning: port)
    }

    private static func echo(_ connection: NWConnection) {
      connection.receiveMessage { data, context, _, error in
        let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
          as? NWProtocolWebSocket.Metadata)?.opcode
        guard error == nil, opcode == .text, let data else {
          connection.cancel()
          return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let reply = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: reply, isComplete: true, completion: .idempotent)
        echo(connection)
      }
    }

    private static func refuse(_ connection: NWConnection) {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
        let response = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(
          content: Data(response.utf8), isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
      }
    }
  }

  private final class Recorder {
    var opened: [String] = []
    var send: ((String) -> Void)?
    nonisolated deinit {}
  }

  private static func identity() throws -> RemoteLANIdentity.Loaded {
    let folder = FileManager.default.temporaryDirectory.appending(path: "lan-client-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    return try #require(RemoteLANIdentity.loadOrCreate(at: folder.appending(path: "identity.p12")))
  }

  /// A started host listener and its port; the caller stops it.
  private func lanServer(_ recorder: Recorder, identity: RemoteLANIdentity.Loaded) async throws
    -> (server: RemoteLANServer, port: Int)
  {
    let server = RemoteLANServer(
      identity: identity,
      clientKey: Self.key,
      callbacks: .init(
        opened: { connID, send in
          recorder.opened.append(connID)
          recorder.send = send
        },
        received: { _, text in recorder.send?("echo:" + text) },
        closed: { _ in }
      )
    )
    server.start()
    guard let port = await server.waitUntilReady() else {
      server.stop()
      throw CancellationError()
    }
    return (server, Int(port))
  }

  private static func relaySocket(_ relay: TestRelay, key: String) async throws -> any RemoteClientSocket {
    let port = try #require(await relay.port())
    let url = try #require(URL(string: "ws://127.0.0.1:\(port)/client"))
    return RemoteClientSocketFactory.live.relay(url, key)
  }

  @Test func theLANSocketOpensWithTheRightPinAndKey() async throws {
    let identity = try Self.identity()
    let recorder = Recorder()
    let (server, port) = try await lanServer(recorder, identity: identity)
    defer { server.stop() }
    let socket = RemoteClientSocketFactory.live.lan("127.0.0.1", port, identity.fingerprint, Self.key)
    defer { socket.close() }
    let probe = EventProbe(socket)

    #expect(await probe.next() == .event(.opened))
    socket.send("ping")
    #expect(await probe.next() == .event(.text("pong")))
    socket.send("hello")
    #expect(await probe.next() == .event(.text("echo:hello")))
    #expect(recorder.opened == ["lan-1"])
  }

  @Test func aWrongPinNeverOpens() async throws {
    let identity = try Self.identity()
    let recorder = Recorder()
    let (server, port) = try await lanServer(recorder, identity: identity)
    defer { server.stop() }
    let socket = RemoteClientSocketFactory.live.lan("127.0.0.1", port, String(repeating: "0", count: 64), Self.key)
    defer { socket.close() }
    let probe = EventProbe(socket)

    #expect(await probe.next() == .event(.closed(reason: "certificate pin mismatch")))
    #expect(await probe.next() == .ended)
    #expect(recorder.opened.isEmpty)
  }

  @Test func aWrongKeyNeverOpens() async throws {
    let identity = try Self.identity()
    let recorder = Recorder()
    let (server, port) = try await lanServer(recorder, identity: identity)
    defer { server.stop() }
    let socket = RemoteClientSocketFactory.live.lan("127.0.0.1", port, identity.fingerprint, "wrong-key")
    defer { socket.close() }
    let probe = EventProbe(socket)

    let first = await probe.next()
    guard case .event(.closed(let reason)) = first else {
      Issue.record("expected .closed first, got \(first)")
      return
    }
    #expect(!reason.contains("wrong-key"))
    #expect(await probe.next() == .ended)
    #expect(recorder.opened.isEmpty)
  }

  @Test func anUpgradeWithoutTheMarkerNeverOpens() async throws {
    let identity = try Self.identity()
    let host = try TestRelay(.markerless(identity))
    defer { host.stop() }
    let port = try #require(await host.port())
    let socket = RemoteClientSocketFactory.live.lan("127.0.0.1", Int(port), identity.fingerprint, Self.key)
    defer { socket.close() }
    let probe = EventProbe(socket)

    #expect(await probe.next() == .event(.closed(reason: "key refused")))
    #expect(await probe.next() == .ended)
    #expect(host.authorizations.values.withLock { $0 } == ["Bearer \(Self.key)"])
  }

  @Test func theRelaySocketSendsTheBearerKey() async throws {
    let relay = try TestRelay(.echo)
    defer { relay.stop() }
    let socket = try await Self.relaySocket(relay, key: "k")
    defer { socket.close() }
    let probe = EventProbe(socket)

    #expect(await probe.next() == .event(.opened))
    socket.send("hi")
    #expect(await probe.next() == .event(.text("hi")))
    #expect(relay.authorizations.values.withLock { $0 } == ["Bearer k"])
  }

  @Test func aRefusedRelayUpgradeClosesWithTheStatus() async throws {
    let relay = try TestRelay(.unauthorized)
    defer { relay.stop() }
    let socket = try await Self.relaySocket(relay, key: "k")
    defer { socket.close() }
    let probe = EventProbe(socket)

    #expect(await probe.next() == .event(.closed(reason: "401")))
    #expect(await probe.next() == .ended)
  }

  @Test func closeEndsTheStream() async throws {
    let relay = try TestRelay(.echo)
    defer { relay.stop() }
    let relaySocket = try await Self.relaySocket(relay, key: "k")
    let identity = try Self.identity()
    let recorder = Recorder()
    let (server, port) = try await lanServer(recorder, identity: identity)
    defer { server.stop() }
    let lanSocket = RemoteClientSocketFactory.live.lan("127.0.0.1", port, identity.fingerprint, Self.key)

    for socket in [relaySocket, lanSocket] {
      let probe = EventProbe(socket)
      #expect(await probe.next() == .event(.opened))
      socket.close()
      socket.close()
      socket.send("after close")
      #expect(await probe.next() == .event(.closed(reason: "closed")))
      #expect(await probe.next() == .ended)
    }
  }
}
