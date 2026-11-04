import CryptoKit
import Foundation
import Security
import Synchronization
import Testing

@testable import supacode

/// A phone-side client of the TLS 1.3 LAN shortcut over a real loopback socket,
/// with a fresh identity made by the same code the app uses.
@MainActor
struct RemoteAccessLANServerTests {
  private static let key = "abcde-fghij-klmno-pqrst-uvwxy-z2345"

  private final class Recorder {
    var received: [String] = []
    var send: ((String) -> Void)?
    var opened: [String] = []
    nonisolated deinit {}
  }

  /// How a WebSocket task ended its opening handshake.
  nonisolated enum Outcome: Equatable, Sendable {
    case opened
    case failed
    case timedOut
  }

  /// Trusts only the certificate whose DER SHA-256 equals `fingerprint`, like the phone,
  /// and reports whether the upgrade opened or the task failed (`outcome(within:)`).
  nonisolated private final class PinningDelegate: NSObject, URLSessionWebSocketDelegate {
    nonisolated private struct State {
      var outcome: Outcome?
      var waiter: CheckedContinuation<Outcome, Never>?
    }

    let fingerprint: String
    private let state = Mutex(State())
    init(fingerprint: String) { self.fingerprint = fingerprint }

    /// The first outcome, or `.timedOut` when none arrives within `seconds`.
    func outcome(within seconds: TimeInterval) async -> Outcome {
      await withCheckedContinuation { continuation in
        let known = state.withLock { current -> Outcome? in
          if let outcome = current.outcome { return outcome }
          current.waiter = continuation
          return nil
        }
        if let known {
          continuation.resume(returning: known)
          return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { self.finish(.timedOut) }
      }
    }

    private func finish(_ outcome: Outcome) {
      let waiter = state.withLock { current -> CheckedContinuation<Outcome, Never>? in
        guard current.outcome == nil else { return nil }
        current.outcome = outcome
        defer { current.waiter = nil }
        return current.waiter
      }
      waiter?.resume(returning: outcome)
    }

    func urlSession(
      _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol subprotocol: String?
    ) {
      finish(.opened)
    }

    func urlSession(
      _ session: URLSession,
      webSocketTask: URLSessionWebSocketTask,
      didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
      reason: Data?
    ) {
      finish(.failed)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
      finish(.failed)
    }

    func urlSession(
      _ session: URLSession,
      didReceive challenge: URLAuthenticationChallenge,
      completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
      guard let trust = challenge.protectionSpace.serverTrust,
        let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
        RemoteLANIdentity.fingerprint(der: SecCertificateCopyData(leaf) as Data) == fingerprint
      else {
        completionHandler(.cancelAuthenticationChallenge, nil)
        return
      }
      completionHandler(.useCredential, URLCredential(trust: trust))
    }
  }

  private static func identity() throws -> RemoteLANIdentity.Loaded {
    let folder = FileManager.default.temporaryDirectory.appending(path: "lan-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    return try #require(RemoteLANIdentity.loadOrCreate(at: folder.appending(path: "identity.p12")))
  }

  private func server(_ recorder: Recorder, identity: RemoteLANIdentity.Loaded) -> RemoteLANServer {
    RemoteLANServer(
      identity: identity,
      clientKey: Self.key,
      callbacks: .init(
        opened: { connID, send in
          recorder.opened.append(connID)
          recorder.send = send
        },
        received: { _, text in
          recorder.received.append(text)
          recorder.send?("echo:" + text)
        },
        closed: { _ in }
      )
    )
  }

  private func socket(
    port: UInt16, fingerprint: String, key: String
  ) -> (task: URLSessionWebSocketTask, delegate: PinningDelegate) {
    var request = URLRequest(url: URL(string: "wss://127.0.0.1:\(port)/lan")!)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    let delegate = PinningDelegate(fingerprint: fingerprint)
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    return (session.webSocketTask(with: request), delegate)
  }

  @Test(.timeLimit(.minutes(1))) func pinnedTLSAndKeyCarryTextBothWays() async throws {
    let identity = try Self.identity()
    #expect(identity.fingerprint.count == 64)
    let recorder = Recorder()
    let server = server(recorder, identity: identity)
    server.start()
    defer { server.stop() }
    let port = try #require(await server.waitUntilReady())
    let socket = socket(port: port, fingerprint: identity.fingerprint, key: Self.key).task
    socket.resume()
    defer { socket.cancel() }

    try await socket.send(.string("ping"))
    try await socket.send(.string(#"{"t":"list","id":1}"#))
    guard case .string(let first) = try await socket.receive(),
      case .string(let second) = try await socket.receive()
    else {
      Issue.record("expected text frames")
      return
    }
    #expect(first == "pong")
    #expect(second == #"echo:{"t":"list","id":1}"#)
    #expect(recorder.opened == ["lan-1"])
  }

  @Test(.timeLimit(.minutes(1))) func wrongKeyIsRefusedAtTheUpgrade() async throws {
    let identity = try Self.identity()
    let recorder = Recorder()
    let server = server(recorder, identity: identity)
    server.start()
    defer { server.stop() }
    let port = try #require(await server.waitUntilReady())
    let (socket, delegate) = socket(port: port, fingerprint: identity.fingerprint, key: "wrong-key")
    socket.resume()
    defer { socket.cancel() }
    // A send or receive on a refused task may never return; wait for the task itself.
    // The server closes a rejected upgrade at once (it reaches `.ready` without the marker).
    #expect(await delegate.outcome(within: 30) == .failed)
    #expect((socket.response as? HTTPURLResponse)?.statusCode != 101)
    #expect(recorder.opened.isEmpty)
  }

  @Test(.timeLimit(.minutes(1))) func anotherCertificateIsNotTrusted() async throws {
    let identity = try Self.identity()
    let recorder = Recorder()
    let server = server(recorder, identity: identity)
    server.start()
    defer { server.stop() }
    let port = try #require(await server.waitUntilReady())
    let socket = socket(port: port, fingerprint: String(repeating: "0", count: 64), key: Self.key).task
    socket.resume()
    defer { socket.cancel() }
    await #expect(throws: (any Error).self) {
      try await socket.send(.string("ping"))
      _ = try await socket.receive()
    }
    #expect(recorder.opened.isEmpty)
  }

  @Test func fingerprintMACBindsTheKeyAndMatchesTheVector() {
    let fingerprint = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
    let mac = RemoteLANIdentity.fingerprintMAC(fingerprint: fingerprint, clientKey: Self.key)
    #expect(mac == Self.fpMacVector)
    #expect(mac != RemoteLANIdentity.fingerprintMAC(fingerprint: fingerprint, clientKey: "other"))
  }

  /// Node: createHmac("sha256", key).update("supacode-lan-fp-v1:" + fp).digest("hex").
  private static let fpMacVector = "e1bef7bccaed983a401062bd7faa05f9fa1a1ca2315570c82009429bdde65a77"

  @Test func offeredAddressesComeFromPhysicalInterfacesOnly() {
    #expect(RemoteLANServer.isOfferable(interface: "en0", ipv4: [172, 10, 9, 102]))
    #expect(RemoteLANServer.isOfferable(interface: "en7", ipv4: [192, 168, 1, 10]))
    #expect(!RemoteLANServer.isOfferable(interface: "feth3014", ipv4: [172, 22, 172, 63]))
    #expect(!RemoteLANServer.isOfferable(interface: "en0", ipv4: [169, 254, 1, 2]))
    #expect(!RemoteLANServer.isOfferable(interface: "utun3", ipv4: [10, 0, 0, 2]))
    #expect(!RemoteLANServer.isOfferable(interface: "en0", ipv4: [127, 0, 0, 1]))
  }

  @Test func clientKeyComesFromTheConnectionKeyFile() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "remote-key-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: url) }
    try "relay.example.com/abcde-fghij\n".write(to: url, atomically: true, encoding: .utf8)
    #expect(RemoteAccessConfig.loadClientKey(from: url) == "abcde-fghij")
    try "abcde-fghij".write(to: url, atomically: true, encoding: .utf8)
    #expect(RemoteAccessConfig.loadClientKey(from: url) == "abcde-fghij")
  }

  @Test func constantTimeEqual() {
    #expect(RemoteLANServer.constantTimeEqual(Data("abc".utf8), Data("abc".utf8)))
    #expect(!RemoteLANServer.constantTimeEqual(Data("abc".utf8), Data("abd".utf8)))
    #expect(!RemoteLANServer.constantTimeEqual(Data("abc".utf8), Data("abcd".utf8)))
  }
}
