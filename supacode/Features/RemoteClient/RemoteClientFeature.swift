import ComposableArchitecture
import ConcurrencyExtras
import Foundation
import Sharing
import SupacodeSettingsShared

/// The "Remote Mac" window (ПЗ1): which Mac it shows, the state of the connection to it and the
/// last `list` it sent. The live objects (sockets, pipes, surfaces) stay in `RemoteClientSession`;
/// the reducer reaches them only through `RemoteClientSessionClient`. Nothing here enters
/// `RepositoriesFeature` or `TerminalsFeature` (ПЗ3).
@Reducer
struct RemoteClientFeature {
  /// App storage key of the selected Mac (МХ1): plain, not secret.
  nonisolated static let selectedHostKey = "remoteClientSelectedHostID"

  @ObservableState
  struct State: Equatable {
    @Shared(.appStorage(RemoteClientFeature.selectedHostKey)) var selectedHostID: String?
    var status: RemoteClientStatus = .idle
    var hasKeyFile = true
    var hostName: String?
    var hosts: [RemoteClientHostInfo] = []
    var isHostPickerPresented = false
    var list: RemoteClientList?
    var selectedWorktreeID: String?
    /// This Mac's own host id: never pickable (МХ2).
    var ownHostID: String?

    /// The picker's rows: every Mac the relay lists except this one.
    var pickableHosts: [RemoteClientHostInfo] {
      RemoteHostChoice.pickable(hosts, ownHostID: ownHostID)
    }

    /// Every worktree of the last `list`, repository by repository.
    var worktrees: [RemoteClientWorktree] {
      list?.repos.flatMap(\.worktrees) ?? []
    }

    var selectedWorktree: RemoteClientWorktree? {
      guard let selectedWorktreeID else { return nil }
      return worktrees.first { $0.id == selectedWorktreeID }
    }
  }

  enum Action {
    case windowAppeared
    case windowClosed
    case statusChanged(RemoteClientStatus)
    case hostNameChanged(String?)
    case hostsChanged([RemoteClientHostInfo]?)
    case listChanged(RemoteClientList)
    case hostPicked(String)
    case hostPickerDismissed
    case titleTapped
    case worktreeSelected(String)
  }

  nonisolated private enum CancelID: Hashable, Sendable { case events }

  @Dependency(\.remoteClientSession) var session

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .windowAppeared:
        state.ownHostID = session.ownHostID()
        guard session.hasKeyFile() else {
          // A key removed since the last opening: nothing stays connected on it.
          state.hasKeyFile = false
          let session = session
          return .merge(
            .cancel(id: CancelID.events),
            .run { _ in await session.close() }
          )
        }
        state.hasKeyFile = true
        let hostID = state.selectedHostID
        let session = session
        // Subscribe before opening, so the first status of the new connection is not missed.
        return .run { send in
          let events = await session.events()
          await session.open(hostID)
          for await event in events {
            await send(event.action)
          }
        }
        .cancellable(id: CancelID.events, cancelInFlight: true)

      case .windowClosed:
        state.status = .idle
        state.hostName = nil
        state.hosts = []
        state.list = nil
        state.selectedWorktreeID = nil
        state.isHostPickerPresented = false
        let session = session
        return .merge(
          .cancel(id: CancelID.events),
          .run { _ in await session.close() }
        )

      case .statusChanged(let status):
        state.status = status
        return .none

      case .hostNameChanged(let name):
        state.hostName = name
        return .none

      case .hostsChanged(let hosts):
        state.hosts = hosts ?? []
        switch RemoteHostChoice.decide(saved: state.selectedHostID, hosts: hosts, ownHostID: state.ownHostID) {
        case .none:
          return .none
        case .askUser:
          // The saved Mac stays saved: only the user changes it (МХ1).
          state.isHostPickerPresented = true
          return .none
        case .select(let hostID):
          return switchHost(to: hostID, state: &state)
        }

      case .listChanged(let list):
        state.list = list
        // The laptop's choice stays while that worktree exists (СЛ4); otherwise the one the Mac
        // shows, else the first.
        if state.selectedWorktree == nil {
          let worktrees = state.worktrees
          state.selectedWorktreeID = (worktrees.first(where: \.focused) ?? worktrees.first)?.id
        }
        return .none

      case .hostPicked(let hostID):
        return switchHost(to: hostID, state: &state)

      case .hostPickerDismissed:
        state.isHostPickerPresented = false
        return .none

      case .titleTapped:
        state.isHostPickerPresented = true
        return .none

      case .worktreeSelected(let worktreeID):
        state.selectedWorktreeID = worktreeID
        return .none
      }
    }
  }

  /// Saves the Mac, forgets what the old one showed and reconnects bound to it (МХ3).
  private func switchHost(to hostID: String, state: inout State) -> Effect<Action> {
    state.$selectedHostID.withLock { $0 = hostID }
    state.list = nil
    state.selectedWorktreeID = nil
    state.isHostPickerPresented = false
    let session = session
    return .run { _ in await session.open(hostID) }
  }
}

extension RemoteClientSessionClient.Event {
  fileprivate var action: RemoteClientFeature.Action {
    switch self {
    case .statusChanged(let status): .statusChanged(status)
    case .hostNameChanged(let name): .hostNameChanged(name)
    case .hostsChanged(let hosts): .hostsChanged(hosts)
    case .listChanged(let list): .listChanged(list)
    }
  }
}

/// The reducer's door to the window's `RemoteClientSession`, so tests need no socket.
nonisolated struct RemoteClientSessionClient: Sendable {
  /// What the session reports, one case per `…Changed` action.
  enum Event: Equatable, Sendable {
    case statusChanged(RemoteClientStatus)
    case hostNameChanged(String?)
    case hostsChanged([RemoteClientHostInfo]?)
    case listChanged(RemoteClientList)
  }

  /// Whether the connection key file exists and parses (КЛ1).
  var hasKeyFile: @MainActor @Sendable () -> Bool
  /// Connects bound to the Mac, or unbound (nil) to read the host list.
  var open: @MainActor @Sendable (_ hostID: String?) -> Void
  var close: @MainActor @Sendable () -> Void
  /// The session's reports; a new call replaces the previous subscriber.
  var events: @MainActor @Sendable () -> AsyncStream<Event>
  var ownHostID: @MainActor @Sendable () -> String?
}

extension RemoteClientSessionClient {
  @MainActor
  static func live(_ session: RemoteClientSession) -> RemoteClientSessionClient {
    RemoteClientSessionClient(
      hasKeyFile: { RemoteClientKey.load() != nil },
      open: { session.open(hostID: $0) },
      close: { session.close() },
      events: { session.events() },
      ownHostID: { session.ownHostID }
    )
  }
}

nonisolated extension RemoteClientSessionClient: DependencyKey {
  /// The window's store replaces this with `.live(session)`; reaching it means that wiring is missing.
  static let liveValue = RemoteClientSessionClient(
    hasKeyFile: { false },
    open: { _ in SupaLogger("RemoteClient").error("Remote client session used without a window") },
    close: {},
    events: { .finished },
    ownHostID: { nil }
  )

  static let testValue = RemoteClientSessionClient(
    hasKeyFile: unimplemented("RemoteClientSessionClient.hasKeyFile", placeholder: false),
    open: unimplemented("RemoteClientSessionClient.open"),
    close: unimplemented("RemoteClientSessionClient.close"),
    events: unimplemented("RemoteClientSessionClient.events", placeholder: .finished),
    ownHostID: unimplemented("RemoteClientSessionClient.ownHostID", placeholder: nil)
  )
}

nonisolated extension DependencyValues {
  var remoteClientSession: RemoteClientSessionClient {
    get { self[RemoteClientSessionClient.self] }
    set { self[RemoteClientSessionClient.self] = newValue }
  }
}
