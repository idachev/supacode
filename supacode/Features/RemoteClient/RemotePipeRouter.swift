import Foundation

/// The app's one `RemotePipeServer`, shared by every remote window's session. The server listens on
/// one socket per process, so two servers would take the file from each other.
///
/// Each session takes its own prefix and names a pipe `<prefix>.<content id>`: two Macs that use
/// the same content id get two pipes, and the server's one callback of each kind is routed back to
/// the session that owns the prefix. The prefix is local (`s1`, `s2`, …): no host id, which comes
/// from another machine, reaches the surface's command line or the pipe header. The server listens
/// while any session uses it and stops with the last one.
@MainActor
final class RemotePipeRouter {
  /// What one session does with its pipes' events, by remote content id.
  struct Route {
    var onOpened: @MainActor (_ contentID: String) -> Void
    var onInput: @MainActor (_ contentID: String, _ bytes: [UInt8]) -> Void
    var onClosed: @MainActor (_ contentID: String) -> Void
  }

  static let shared = RemotePipeRouter(directory: RemoteClientSession.pipeDirectory)

  let server: RemotePipeServer
  private var routes: [String: Route] = [:]
  private var lastPrefix = 0

  var socketPath: String { server.socketPath }

  init(directory: URL) {
    server = RemotePipeServer(directory: directory)
    server.onOpened = { [weak self] key in
      self?.deliver(key) { route, contentID in route.onOpened(contentID) }
    }
    server.onInput = { [weak self] key, bytes in
      self?.deliver(key) { route, contentID in route.onInput(contentID, bytes) }
    }
    server.onClosed = { [weak self] key in
      self?.deliver(key) { route, contentID in route.onClosed(contentID) }
    }
  }

  nonisolated deinit {}

  /// A prefix no other session of this router has.
  func makePrefix() -> String {
    lastPrefix += 1
    return "s\(lastPrefix)"
  }

  /// `<prefix>.<content id>`: the word the surface's `remote-pipe` and its header carry. The prefix
  /// holds no `.`, so the first one splits it off again.
  nonisolated static func pipeKey(prefix: String, contentID: String) -> String {
    "\(prefix).\(contentID)"
  }

  /// Routes the prefix's pipes to `route`, starting the server if it is not listening yet.
  func start(prefix: String, route: Route) throws {
    try server.start()
    routes[prefix] = route
  }

  /// Stops routing the prefix; the server stops with the last one. The owner tore its contents
  /// down first, so none of its pipes is left on the server.
  func stop(prefix: String) {
    routes[prefix] = nil
    guard routes.isEmpty else { return }
    server.stop()
  }

  func expect(prefix: String, contentID: String) -> String {
    server.expect(contentID: Self.pipeKey(prefix: prefix, contentID: contentID))
  }

  func forget(prefix: String, contentID: String) {
    server.forget(contentID: Self.pipeKey(prefix: prefix, contentID: contentID))
  }

  func write(prefix: String, contentID: String, _ bytes: [UInt8]) {
    server.write(contentID: Self.pipeKey(prefix: prefix, contentID: contentID), bytes)
  }

  /// A report for a prefix no session routes (stopped, or never ours) finds nothing.
  private func deliver(_ key: String, _ body: (Route, String) -> Void) {
    guard let dot = key.firstIndex(of: "."), let route = routes[String(key[..<dot])] else { return }
    body(route, String(key[key.index(after: dot)...]))
  }
}
