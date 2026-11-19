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
    /// The connection was `.online` since the window last opened it: a status that is not online
    /// now is then a lost link (БН3).
    var hasBeenOnline = false
    var hosts: [RemoteClientHostInfo] = []
    var isHostPickerPresented = false
    var list: RemoteClientList?
    var selectedWorktreeID: String?
    /// This Mac's own host id: never pickable (МХ2).
    var ownHostID: String?
    /// The sidebar's local filter (СЛ3).
    var filterText = ""
    /// The sidebar of the last `list` under `filterText`, kept so the view never rebuilds it.
    var sidebarSections: [RemoteSidebarModel.Section] = []
    /// Worktree id → the laptop's choices in its layout (РЗ2); a worktree that is gone leaves.
    var selections: [String: RemoteLocalSelection] = [:]
    /// The selected worktree's layout as the window draws it.
    var projection: RemoteLayoutProjection?
    /// The branch-name prompt of New Worktree, while it is open.
    var newWorktree: NewWorktreePrompt?
    /// Requests in flight by key (`RequestKey`): their buttons are disabled.
    var busyRequests: Set<String> = []
    /// Worktree id → a tab a reply created there: selected once a `list` holds it.
    var pendingTabs: [String: String] = [:]
    /// A worktree `worktree.new` created: selected once a `list` holds it.
    var pendingWorktreeID: String?
    /// Request key of each `worktree.new` in flight → the worktree selected when it was confirmed
    /// (nil: none). Its reply selects the new worktree only if that is still the selection.
    var newWorktreeOrigins: [String: String?] = [:]
    @Presents var alert: AlertState<Action.Alert>?

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

    /// The repository of the selected worktree.
    var selectedRepository: RemoteClientRepository? {
      guard let selectedWorktreeID else { return nil }
      return list?.repos.first { $0.worktrees.contains { $0.id == selectedWorktreeID } }
    }

    /// The sidebar's rows top to bottom, as shown under the filter: the order of Select Worktree N
    /// and Select Next / Previous.
    var sidebarRowIDs: [String] {
      sidebarSections.flatMap { $0.rows.map(\.id) }
    }
  }

  struct NewWorktreePrompt: Equatable, Sendable {
    let repositoryID: String
    var name = ""
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
    case filterChanged(String)
    case tabSelected(paneID: String, tabID: String)
    case paneFocused(String)
    case zoomToggled(paneID: String)
    case groupSelected(String)
    case newTabTapped(paneID: String?)
    case closeTabTapped(tabID: String)
    case splitTapped(paneID: String, direction: SplitDirection)
    case closePaneTapped(paneID: String)
    case newWorktreeTapped(repositoryID: String)
    case newWorktreeNameChanged(String)
    case newWorktreeConfirmed
    case newWorktreeCancelled
    case deleteWorktreeTapped(worktreeID: String)
    case refreshTapped
    /// A Worktrees menu item while the remote window is key (R20).
    case worktreeCommand(RemoteWorktreeCommand)
    case requestFinished(key: String, Result<[String: String], RemoteClientRequestError>)
    case alert(PresentationAction<Alert>)

    nonisolated enum Alert: Equatable, Sendable {
      case confirmCloseTab(String)
      case confirmClosePane(String)
      case confirmDeleteWorktree(String)
    }
  }

  nonisolated enum CancelID: Hashable, Sendable {
    case events
    /// Every remote request: cancelled when the window closes or the Mac changes, so a reply for
    /// the old Mac never reaches the state.
    case requests
    /// The latest visible set; a newer one replaces one not delivered yet.
    case visible
  }

  @Dependency(\.remoteClientSession) var session

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      reduceSelection(&state, action)
    }
    Reduce { state, action in
      reduceRequests(&state, action)
    }
    .ifLet(\.$alert, action: \.alert)
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
        state.hasBeenOnline = false
        return connect(state.selectedHostID)

      case .windowClosed:
        state.status = .idle
        state.hostName = nil
        state.hosts = []
        state.isHostPickerPresented = false
        forgetMac(&state)
        let session = session
        // The cancel also stops a reopen that has not connected yet (`connect`).
        return .merge(
          .cancel(id: CancelID.events),
          .cancel(id: CancelID.requests),
          .cancel(id: CancelID.visible),
          .run { _ in await session.close() }
        )

      case .statusChanged(let status):
        state.status = status
        if case .online = status { state.hasBeenOnline = true }
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
        return listChanged(list, state: &state)

      case .hostPicked(let hostID):
        return switchHost(to: hostID, state: &state)

      case .hostPickerDismissed:
        state.isHostPickerPresented = false
        return .none

      case .titleTapped:
        state.isHostPickerPresented = true
        return .none

      default:
        return .none
      }
    }
  }

  /// Saves the Mac, forgets what the old one showed and reconnects bound to it (МХ3).
  private func switchHost(to hostID: String, state: inout State) -> Effect<Action> {
    state.$selectedHostID.withLock { $0 = hostID }
    state.isHostPickerPresented = false
    forgetMac(&state)
    return .merge(.cancel(id: CancelID.requests), .cancel(id: CancelID.visible), connect(hostID))
  }

  /// Drops everything the window knew about the Mac it showed.
  private func forgetMac(_ state: inout State) {
    state.hasBeenOnline = false
    state.list = nil
    state.selectedWorktreeID = nil
    state.sidebarSections = []
    state.selections = [:]
    state.projection = nil
    state.newWorktree = nil
    state.busyRequests = []
    state.pendingTabs = [:]
    state.pendingWorktreeID = nil
    state.newWorktreeOrigins = [:]
    state.alert = nil
  }

  /// Subscribes to the session's reports, opens the connection and forwards the reports, as one
  /// effect: closing the window, or a newer opening, cancels it. Subscribing and opening happen in
  /// one main-actor step that checks for that cancel first, so a cancelled reopen never connects
  /// after the window closed (КЛ6); reports the old effect had not sent yet are dropped with it.
  private func connect(_ hostID: String?) -> Effect<Action> {
    let session = session
    return .run { send in
      let events = await MainActor.run { () -> AsyncStream<RemoteClientSessionClient.Event>? in
        guard !Task.isCancelled else { return nil }
        // Subscribe before opening, so the first status of the new connection is not missed.
        let events = session.events()
        session.open(hostID)
        return events
      }
      guard let events else { return }
      for await event in events {
        await send(event.action)
      }
    }
    .cancellable(id: CancelID.events, cancelInFlight: true)
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
  /// A request with an `id` on the connection; throws `RemoteClientRequestError`.
  var request:
    @MainActor @Sendable (
      _ t: String, _ fields: [String: String], _ ints: [String: Int], _ timeout: Duration
    ) async throws -> [String: String]
  /// The remote contents the window shows now; drives the attached set (РЗ5).
  var setVisible: @MainActor @Sendable (_ contentIDs: [String]) -> Void
  /// The grid that fits the pane at this Mac's font, when measured.
  var fittingGrid: @MainActor @Sendable (_ paneID: String) -> RemoteAutoResize.Grid?
}

extension RemoteClientSessionClient {
  @MainActor
  static func live(_ session: RemoteClientSession) -> RemoteClientSessionClient {
    RemoteClientSessionClient(
      hasKeyFile: { session.hasKeyFile },
      open: { session.open(hostID: $0) },
      close: { session.close() },
      events: { session.events() },
      ownHostID: { session.ownHostID },
      request: { try await session.request($0, $1, ints: $2, timeout: $3) },
      setVisible: { session.setVisible($0) },
      fittingGrid: { session.fittingGrid($0) }
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
    ownHostID: { nil },
    request: { _, _, _, _ in
      throw RemoteClientRequestError(kind: .notConnected, message: "Not connected to the Mac", code: nil)
    },
    setVisible: { _ in },
    fittingGrid: { _ in nil }
  )

  static let testValue = RemoteClientSessionClient(
    hasKeyFile: unimplemented("RemoteClientSessionClient.hasKeyFile", placeholder: false),
    open: unimplemented("RemoteClientSessionClient.open"),
    close: unimplemented("RemoteClientSessionClient.close"),
    events: unimplemented("RemoteClientSessionClient.events", placeholder: .finished),
    ownHostID: unimplemented("RemoteClientSessionClient.ownHostID", placeholder: nil),
    request: unimplemented("RemoteClientSessionClient.request"),
    setVisible: unimplemented("RemoteClientSessionClient.setVisible"),
    fittingGrid: unimplemented("RemoteClientSessionClient.fittingGrid", placeholder: nil)
  )
}

nonisolated extension DependencyValues {
  var remoteClientSession: RemoteClientSessionClient {
    get { self[RemoteClientSessionClient.self] }
    set { self[RemoteClientSessionClient.self] = newValue }
  }
}
