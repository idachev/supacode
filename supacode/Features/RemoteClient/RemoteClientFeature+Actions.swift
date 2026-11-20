import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

nonisolated private let remoteActionsLogger = SupaLogger("RemoteClient")

// Local selection (РЗ2, СЛ3, СЛ4) and the remote actions (СЛ5, РЗ1, РЗ4) of the remote window.
extension RemoteClientFeature {
  /// Request timeouts, from the protocol's client contract.
  nonisolated enum Timeout {
    static let worktreeNew: Duration = .seconds(320)
    static let worktreeDelete: Duration = .seconds(310)
    static let worktreesRefresh: Duration = .seconds(70)
    /// `tab.new` and `pane.split`.
    static let newTerminal: Duration = .seconds(15)
    /// `tab.close` and `pane.close`.
    static let close: Duration = .seconds(10)
  }

  /// `busyRequests` keys: the message type, then `:` and its subject (a worktree, pane, tab or
  /// repository id) when it has one, e.g. `worktree.new:<repository id>`, `worktrees.refresh`.
  nonisolated enum RequestKey {
    static func make(_ type: String, _ subject: String?) -> String {
      subject.map { "\(type):\($0)" } ?? type
    }

    /// `tab.new` is keyed by worktree and pane: a second pane's New Tab is not held back by the
    /// first's. `paneID` is the pane sent, nil for a worktree without `layout`.
    static func newTab(worktreeID: String, paneID: String?) -> String {
      make("tab.new", "\(worktreeID)|\(paneID ?? "")")
    }

    /// The message type of a key. Split at the first `:` only: ids may hold more (paths, ssh hosts).
    static func type(of key: String) -> String {
      key.firstIndex(of: ":").map { String(key[..<$0]) } ?? key
    }
  }

  static let worktreeMayAppear = "Connection lost; the worktree may still appear in the list"
  static let worktreeMayDisappear = "Connection lost; the worktree may still disappear from the list"

  // MARK: - Selection

  /// Local actions: selection actions change only `selections` and re-project; the filter and the
  /// New Worktree prompt stay on the laptop. None of them sends anything to the Mac.
  func reduceSelection(_ state: inout State, _ action: Action) -> Effect<Action> {
    switch action {
    case .newWorktreeTapped(let repositoryID):
      // The Mac offers it per repository (`canCreateWorktree`); otherwise nothing happens.
      guard state.list?.repos.first(where: { $0.id == repositoryID })?.canCreateWorktree == true else {
        return .none
      }
      state.newWorktree = NewWorktreePrompt(repositoryID: repositoryID)
      return .none

    case .worktreeCommand(let command):
      return worktreeCommand(command, state: &state)

    case .newWorktreeNameChanged(let name):
      state.newWorktree?.name = name
      return .none

    case .newWorktreeCancelled:
      state.newWorktree = nil
      return .none

    case .worktreeSelected(let worktreeID):
      state.selectedWorktreeID = worktreeID
      // The laptop's own choice wins over a worktree a reply created that has not shown yet.
      state.pendingWorktreeID = nil
      return reproject(&state)

    case .filterChanged(let text):
      state.filterText = text
      state.sidebarSections = state.list.map { RemoteSidebarModel.sections($0, filter: text) } ?? []
      return .none

    case .tabSelected(let paneID, let tabID):
      return changeSelection(&state) { selection, projection in
        selection.selectedTabID[paneID] = tabID
        if let groupID = projection.groupID(containing: paneID) { selection.focusedPaneID[groupID] = paneID }
      }

    case .paneFocused, .focusSplitTapped:
      return focusPane(action, state: &state)

    case .zoomToggled(let paneID):
      return changeSelection(&state) { selection, projection in
        guard let groupID = projection.groupID(containing: paneID) else { return }
        let isZoomed = selection.zoomedPaneID[groupID] == paneID
        selection.zoomedPaneID[groupID] = isZoomed ? nil : paneID
        selection.focusedPaneID[groupID] = paneID
      }

    case .groupSelected(let groupID):
      return changeSelection(&state) { selection, _ in
        selection.activeGroupID = groupID
      }

    default:
      return .none
    }
  }

  /// A Worktrees menu item (R20). New Worktree opens the prompt for the selected worktree's
  /// repository; selection walks the sidebar's shown rows: Select Worktree N picks row N (nothing
  /// past the end), next and previous wrap, and a selection the filter hides starts from an end.
  private func worktreeCommand(_ command: RemoteWorktreeCommand, state: inout State) -> Effect<Action> {
    let rows = state.sidebarRowIDs
    let current = state.selectedWorktreeID.flatMap { rows.firstIndex(of: $0) }
    let target: String?
    switch command {
    case .newWorktree:
      guard let repositoryID = state.selectedRepository?.id else { return .none }
      return reduceSelection(&state, .newWorktreeTapped(repositoryID: repositoryID))
    case .refreshWorktrees:
      return reduceRequests(&state, .refreshTapped)
    case .selectWorktree(let slot):
      target = rows.indices.contains(slot) ? rows[slot] : nil
    case .selectNextWorktree:
      target = rows.isEmpty ? nil : rows[current.map { ($0 + 1) % rows.count } ?? 0]
    case .selectPreviousWorktree:
      target = rows.isEmpty ? nil : rows[current.map { ($0 - 1 + rows.count) % rows.count } ?? rows.count - 1]
    }
    guard let target, target != state.selectedWorktreeID else { return .none }
    return reduceSelection(&state, .worktreeSelected(target))
  }

  /// A pane takes the focus: the one clicked into (`paneFocused`), or the neighbour Focus Split
  /// picks (`focusSplitTapped`, nothing at an edge).
  private func focusPane(_ action: Action, state: inout State) -> Effect<Action> {
    return changeSelection(&state) { selection, projection in
      let paneID: String? =
        switch action {
        case .paneFocused(let paneID): paneID
        case .focusSplitTapped(let direction): projection.paneID(movingFocus: direction)
        default: nil
        }
      guard let paneID, let groupID = projection.groupID(containing: paneID) else { return }
      selection.focusedPaneID[groupID] = paneID
    }
  }

  /// The selected worktree's choices changed by `change`, then re-projected.
  private func changeSelection(
    _ state: inout State, _ change: (inout RemoteLocalSelection, RemoteLayoutProjection) -> Void
  ) -> Effect<Action> {
    guard let worktreeID = state.selectedWorktreeID, let projection = state.projection else { return .none }
    var selection = state.selections[worktreeID] ?? RemoteLocalSelection()
    change(&selection, projection)
    state.selections[worktreeID] = selection
    return reproject(&state)
  }

  /// A new `list` (pushed, or a `worktrees.refresh` reply): the sidebar, the selected worktree
  /// (kept while it exists, СЛ4; else the one the Mac shows, else the sidebar's first), pending
  /// selections from replies, and the projection.
  func listChanged(_ list: RemoteClientList, state: inout State) -> Effect<Action> {
    state.list = list
    state.sidebarSections = RemoteSidebarModel.sections(list, filter: state.filterText)
    let worktrees = state.worktrees
    let ids = Set(worktrees.map(\.id))
    if let pending = state.pendingWorktreeID, ids.contains(pending) {
      state.selectedWorktreeID = pending
      state.pendingWorktreeID = nil
    }
    if state.selectedWorktree == nil {
      // The unfiltered sidebar: the one already built unless a filter narrows it.
      let isFiltering = !state.filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      let sidebar = isFiltering ? RemoteSidebarModel.sections(list, filter: "") : state.sidebarSections
      let firstRow = sidebar.lazy.flatMap(\.rows).first?.id
      state.selectedWorktreeID = worktrees.first(where: \.focused)?.id ?? firstRow ?? worktrees.first?.id
    }
    state.selections = state.selections.filter { ids.contains($0.key) }
    let creating = state.creatingWorktrees
    state.creatingWorktrees = creating.filter { $0.value.worktreeID.map(ids.contains) != true }
    // A row the list resolved stops its grace timer (`creatingRowGrace`).
    let resolved = creating.keys.filter { state.creatingWorktrees[$0] == nil }.sorted()
    applyPendingTabs(&state)
    let projected = reproject(&state)
    guard !resolved.isEmpty else { return projected }
    return .merge([projected] + resolved.map { .cancel(id: CancelID.creatingRow(repositoryID: $0)) })
  }

  /// Selects each tab a reply created once the list holds it.
  private func applyPendingTabs(_ state: inout State) {
    for (worktreeID, tabID) in state.pendingTabs {
      guard selectTab(tabID, inWorktree: worktreeID, state: &state) else { continue }
      state.pendingTabs[worktreeID] = nil
    }
  }

  /// Selects the tab in its worktree's choices: in its pane, that pane focused, its group active
  /// (in `splitPerTab` a tab is a group, parked or not) and not zoomed on another pane. False when
  /// the list holds no such worktree or tab.
  private func selectTab(_ tabID: String, inWorktree worktreeID: String, state: inout State) -> Bool {
    guard let worktree = state.worktrees.first(where: { $0.id == worktreeID }),
      worktree.tabs.contains(where: { $0.id == tabID })
    else { return false }
    var selection = state.selections[worktreeID] ?? RemoteLocalSelection()
    let projection = RemoteLayoutProjection.project(worktree, selection: &selection)
    guard let pane = projection.panes.values.first(where: { $0.tabs.contains { $0.id == tabID } }),
      let groupID = projection.groupID(containing: pane.id)
    else { return true }
    selection.selectedTabID[pane.id] = tabID
    selection.focusedPaneID[groupID] = pane.id
    selection.activeGroupID = groupID
    if let zoomed = selection.zoomedPaneID[groupID], zoomed != pane.id { selection.zoomedPaneID[groupID] = nil }
    state.selections[worktreeID] = selection
    return true
  }

  /// A notification tap (ИВ3): selects its worktree and, there, the tab that holds the content. A
  /// worktree the list no longer holds changes nothing; a tab gone leaves the worktree selected.
  func notificationOpened(worktreeID: String, contentID: String, state: inout State) -> Effect<Action> {
    guard let worktree = state.worktrees.first(where: { $0.id == worktreeID }) else { return .none }
    state.selectedWorktreeID = worktreeID
    state.pendingWorktreeID = nil
    if let tabID = worktree.tabs.first(where: { $0.contentId == contentID })?.id {
      _ = selectTab(tabID, inWorktree: worktreeID, state: &state)
    }
    return reproject(&state)
  }

  /// Projects the selected worktree and hands its visible contents to the attached set (РЗ5).
  func reproject(_ state: inout State) -> Effect<Action> {
    if let worktree = state.selectedWorktree {
      var selection = state.selections[worktree.id] ?? RemoteLocalSelection()
      state.projection = RemoteLayoutProjection.project(worktree, selection: &selection)
      state.selections[worktree.id] = selection
    } else {
      state.projection = nil
    }
    let visible = state.projection?.visibleContentIDs ?? []
    let session = session
    // One at a time, newest wins: an older set never lands after a newer one.
    return .run { _ in
      await MainActor.run {
        guard !Task.isCancelled else { return }
        session.setVisible(visible)
      }
    }
    .cancellable(id: CancelID.visible, cancelInFlight: true)
  }

  // MARK: - Remote actions

  /// Structural actions become requests (РЗ1): the picture changes with the next `list`.
  func reduceRequests(_ state: inout State, _ action: Action) -> Effect<Action> {
    switch action {
    case .newTabTapped(let paneID):
      return newTab(paneID: paneID, state: &state)

    case .closeTabTapped(let tabID):
      return closeTabTapped(tabID, state: &state)

    case .splitTapped(let paneID, let direction):
      return request(
        "pane.split", subject: paneID, ["paneId": paneID, "direction": direction.rawValue],
        timeout: Timeout.newTerminal, state: &state)

    case .closePaneTapped(let paneID):
      state.alert = Self.confirmClosePaneAlert(paneID)
      return .none

    case .newWorktreeConfirmed:
      return newWorktree(state: &state)

    case .deleteWorktreeTapped(let worktreeID):
      guard let worktree = state.worktrees.first(where: { $0.id == worktreeID }), worktree.canDeleteWorktree else {
        return .none
      }
      state.alert = Self.confirmDeleteWorktreeAlert(worktree)
      return .none

    case .refreshTapped:
      guard state.list?.canRefreshWorktrees == true else { return .none }
      return request("worktrees.refresh", subject: nil, [:], timeout: Timeout.worktreesRefresh, state: &state)

    case .requestFinished(let key, let result):
      return requestFinished(key: key, result, state: &state)

    case .creatingRowExpired(let repositoryID, let worktreeID):
      // A newer creation in the same repository keeps its own row.
      guard state.creatingWorktrees[repositoryID]?.worktreeID == worktreeID else { return .none }
      state.creatingWorktrees[repositoryID] = nil
      return .none

    case .alert(.presented(let alert)):
      return confirmed(alert, state: &state)

    default:
      return .none
    }
  }

  /// `tab.new` in the selected worktree, into `paneID` when given (`newTabPane`), at the fitting
  /// grid of that pane (else of the focused one) when it is known.
  private func newTab(paneID: String?, state: inout State) -> Effect<Action> {
    guard let worktree = state.selectedWorktree else { return .none }
    var fields = ["worktreeId": worktree.id]
    let sentPane = Self.newTabPane(paneID, in: worktree)
    if let sentPane { fields["paneId"] = sentPane }
    var ints: [String: Int] = [:]
    if let gridPane = paneID ?? state.projection?.focusedPaneID, let grid = session.fittingGrid(gridPane) {
      ints = ["cols": grid.columns, "rows": grid.rows]
    }
    let key = RequestKey.newTab(worktreeID: worktree.id, paneID: sentPane)
    return request(key: key, "tab.new", fields, ints: ints, timeout: Timeout.newTerminal, state: &state)
  }

  /// The pane `tab.new` names: none for a worktree without `layout` (it has no real pane ids) and
  /// none in `splitPerTab`, where the host ignores it and a new tab is a new top-level tab. Every
  /// New Tab of such a worktree is then one request, under one busy key.
  static func newTabPane(_ paneID: String?, in worktree: RemoteClientWorktree) -> String? {
    guard let layout = worktree.layout, layout.mode != "splitPerTab" else { return nil }
    return paneID
  }

  /// Close Tab: asks first by this Mac's confirm-close-tab setting (`closeAsksFirst`), else sends.
  private func closeTabTapped(_ tabID: String, state: inout State) -> Effect<Action> {
    guard let tab = state.selectedWorktree?.tabs.first(where: { $0.id == tabID }) else { return .none }
    @Shared(.settingsFile) var settingsFile: SettingsFile
    guard !Self.closeAsksFirst(tab, mode: settingsFile.global.confirmCloseTab) else {
      state.alert = Self.confirmCloseTabAlert(tab)
      return .none
    }
    return closeTab(tabID, state: &state)
  }

  /// Whether Close Tab asks first, by the same confirm-close-tab setting as a local tab. In
  /// `.busy` it asks when closing would interrupt a program on the Mac (ПМ11): the host's `busy`
  /// (a bare shell prompt is not busy, Claude at its prompt is) or `working`. A host that sends
  /// no `busy` counts any tab with an agent as busy instead.
  static func closeAsksFirst(_ tab: RemoteClientTab, mode: ConfirmCloseTabMode) -> Bool {
    switch mode {
    case .always: true
    case .never: false
    case .busy: tab.working || (tab.busy ?? !tab.agents.isEmpty)
    }
  }

  private func closeTab(_ tabID: String, state: inout State) -> Effect<Action> {
    request("tab.close", subject: tabID, ["tabId": tabID], timeout: Timeout.close, state: &state)
  }

  /// `worktree.new` with the trimmed branch name; a blank name does nothing.
  private func newWorktree(state: inout State) -> Effect<Action> {
    guard let prompt = state.newWorktree else { return .none }
    let name = prompt.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = RequestKey.make("worktree.new", prompt.repositoryID)
    guard !name.isEmpty, !state.busyRequests.contains(key) else { return .none }
    state.newWorktree = nil
    state.newWorktreeOrigins.updateValue(state.selectedWorktreeID, forKey: key)
    state.creatingWorktrees[prompt.repositoryID] = CreatingWorktree(name: name)
    return request(
      "worktree.new", subject: prompt.repositoryID, ["repositoryId": prompt.repositoryID, "name": name],
      timeout: Timeout.worktreeNew, state: &state)
  }

  private func confirmed(_ alert: Action.Alert, state: inout State) -> Effect<Action> {
    switch alert {
    case .confirmCloseTab(let tabID):
      return closeTab(tabID, state: &state)
    case .confirmClosePane(let paneID):
      return request("pane.close", subject: paneID, ["paneId": paneID], timeout: Timeout.close, state: &state)
    case .confirmDeleteWorktree(let worktreeID):
      return request(
        "worktree.delete", subject: worktreeID, ["worktreeId": worktreeID], timeout: Timeout.worktreeDelete,
        state: &state)
    }
  }

  /// Sends one request unless the same key is in flight; its outcome comes back as
  /// `requestFinished`. Nothing is retried.
  private func request(
    _ type: String, subject: String?, _ fields: [String: String], ints: [String: Int] = [:],
    timeout: Duration, state: inout State
  ) -> Effect<Action> {
    request(key: RequestKey.make(type, subject), type, fields, ints: ints, timeout: timeout, state: &state)
  }

  private func request(
    key: String, _ type: String, _ fields: [String: String], ints: [String: Int] = [:],
    timeout: Duration, state: inout State
  ) -> Effect<Action> {
    guard state.busyRequests.insert(key).inserted else { return .none }
    let session = session
    return .run { send in
      do {
        let reply = try await session.request(type, fields, ints, timeout)
        await send(.requestFinished(key: key, .success(reply)))
      } catch let error as RemoteClientRequestError {
        await send(.requestFinished(key: key, .failure(error)))
      } catch {
        // Cancelled with the window or the Mac: nobody waits for it.
        guard !Task.isCancelled else { return }
        let lost = RemoteClientRequestError(kind: .connectionLost, message: error.localizedDescription, code: nil)
        await send(.requestFinished(key: key, .failure(lost)))
      }
    }
    .cancellable(id: CancelID.requests)
  }

  /// A reply: frees its key, remembers the tab (and worktree) it created, or shows the failure. A
  /// key no longer in flight belongs to a Mac the window left, and is ignored.
  private func requestFinished(
    key: String, _ result: Result<[String: String], RemoteClientRequestError>, state: inout State
  ) -> Effect<Action> {
    guard state.busyRequests.remove(key) != nil else { return .none }
    let origin = state.newWorktreeOrigins.removeValue(forKey: key)
    let type = RequestKey.type(of: key)
    if type == "worktree.new" { creationFinished(key: key, result, state: &state) }
    switch result {
    case .success(let reply):
      guard ["tab.new", "pane.split", "worktree.new"].contains(type), let worktreeID = reply["worktreeId"] else {
        return .none
      }
      // A new worktree is selected too, or its selected tab would not show; not when the laptop
      // picked another worktree while the request ran.
      if type == "worktree.new", let origin, origin == state.selectedWorktreeID {
        state.pendingWorktreeID = worktreeID
      }
      if let tabID = reply["tabId"] { state.pendingTabs[worktreeID] = tabID }
      // The list that holds it may have come before the reply.
      let applied = state.list.map { listChanged($0, state: &state) } ?? .none
      // After the re-run: a row the list already resolved needs no grace.
      return .merge(applied, creatingRowGrace(key: key, worktreeID: worktreeID, state: state))
    case .failure(let error):
      remoteActionsLogger.warning("Remote \(type) failed (\(error.kind))")
      state.alert = Self.failureAlert(title: Self.failureTitle(type), message: Self.failureMessage(type, error))
      return .none
    }
  }

  /// How long a replied `worktree.new` row waits for a list that holds its worktree. The Mac has
  /// made the worktree by then, so a list that never shows it (a stalled push) must not leave the
  /// spinner forever (ДР2).
  static let creatingRowGrace: Duration = .seconds(30)

  /// The grace timer of a `worktree.new` row that still waits for `worktreeID`; none otherwise.
  /// Closing the window or switching the Mac cancels it with the requests.
  private func creatingRowGrace(key: String, worktreeID: String, state: State) -> Effect<Action> {
    guard RequestKey.type(of: key) == "worktree.new" else { return .none }
    let repositoryID = String(key.dropFirst("worktree.new:".count))
    guard state.creatingWorktrees[repositoryID]?.worktreeID == worktreeID else { return .none }
    let clock = clock
    return .run { send in
      try await clock.sleep(for: Self.creatingRowGrace)
      await send(.creatingRowExpired(repositoryID: repositoryID, worktreeID: worktreeID))
    }
    .cancellable(id: CancelID.creatingRow(repositoryID: repositoryID), cancelInFlight: true)
    .cancellable(id: CancelID.requests)
  }

  /// A `worktree.new` reply: a failure, or a reply without the worktree's id, removes its progress
  /// row; a success names the worktree the row waits for. `listChanged` removes the row once the
  /// list holds that worktree; the caller re-runs it for a list that came before the reply.
  private func creationFinished(
    key: String, _ result: Result<[String: String], RemoteClientRequestError>, state: inout State
  ) {
    let repositoryID = String(key.dropFirst("worktree.new:".count))
    guard case .success(let reply) = result, let worktreeID = reply["worktreeId"] else {
      state.creatingWorktrees[repositoryID] = nil
      return
    }
    state.creatingWorktrees[repositoryID]?.worktreeID = worktreeID
  }

  // MARK: - Alerts

  /// The text of a failed request: the host's message as is; a lost wait of a worktree change
  /// says the change may still land (К2, К7).
  static func failureMessage(_ type: String, _ error: RemoteClientRequestError) -> String {
    switch error.kind {
    case .host:
      return error.message.isEmpty ? "The Mac refused the request" : error.message
    case .notConnected:
      return "Not connected to the Mac"
    case .timeout, .connectionLost:
      switch type {
      case "worktree.new": return worktreeMayAppear
      case "worktree.delete": return worktreeMayDisappear
      default:
        return error.kind == .timeout ? "The Mac did not answer in time" : "The connection to the Mac was lost"
      }
    }
  }

  static func failureTitle(_ type: String) -> String {
    switch type {
    case "worktree.new": "Could Not Create the Worktree"
    case "worktree.delete": "Could Not Delete the Worktree"
    case "worktrees.refresh": "Could Not Refresh the Worktrees"
    case "tab.new": "Could Not Open a Tab"
    case "tab.close": "Could Not Close the Tab"
    case "pane.split": "Could Not Split the Pane"
    case "pane.close": "Could Not Close the Pane"
    default: "The Request Failed"
    }
  }

  static func failureAlert(title: String, message: String) -> AlertState<Action.Alert> {
    AlertState {
      TextState(title)
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState(message)
    }
  }

  static func confirmCloseTabAlert(_ tab: RemoteClientTab) -> AlertState<Action.Alert> {
    let name = tab.title.isEmpty ? "This tab" : "“\(tab.title)”"
    return AlertState {
      TextState("Close Tab?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmCloseTab(tab.id)) {
        TextState("Close Tab")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState("\(name) is still running on the Mac. Closing it ends its terminal there.")
    }
  }

  static func confirmClosePaneAlert(_ paneID: String) -> AlertState<Action.Alert> {
    AlertState {
      TextState("Close Pane?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmClosePane(paneID)) {
        TextState("Close Pane")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState("Every tab of this pane closes on the Mac, and their terminals end.")
    }
  }

  static func confirmDeleteWorktreeAlert(_ worktree: RemoteClientWorktree) -> AlertState<Action.Alert> {
    let name = worktree.name.isEmpty ? worktree.branch : worktree.name
    return AlertState {
      TextState("Delete Worktree?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmDeleteWorktree(worktree.id)) {
        TextState("Delete")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState(
        "“\(name)” is deleted on the Mac; its branch stays. Uncommitted, untracked or ignored files stop the delete.")
    }
  }
}

extension RemoteLayoutProjection {
  /// The group the window shows.
  var activeGroup: GroupView? {
    groups.first { $0.id == activeGroupID }
  }

  /// The pane Focus Split (⌘⌥+arrow) moves to from the active group's focused pane, by the local
  /// layout's spatial rule (`SplitTree.focusTarget`), so both windows pick the same neighbour.
  /// Nil at an edge, with one pane, or while the group is zoomed (only one pane shows).
  func paneID(movingFocus direction: TerminalSplitMenuDirection) -> String? {
    guard let group = activeGroup, group.zoomedPaneID == nil, let focused = group.focusedPaneID else { return nil }
    let tree = SplitTree<RemotePaneLeaf>(root: Self.splitNode(group.tree))
    guard let node = tree.find(id: focused) else { return nil }
    let spatial: SplitTree<RemotePaneLeaf>.SpatialDirection =
      switch direction {
      case .right: .right
      case .left: .left
      case .down: .down
      case .up: .top
      }
    guard let target = tree.focusTarget(for: .spatial(spatial), from: node)?.id, target != focused else {
      return nil
    }
    return target
  }

  /// The remote tree as a local split tree; an axis this client does not know reads as horizontal.
  private static func splitNode(_ node: RemoteClientLayoutNode) -> SplitTree<RemotePaneLeaf>.Node {
    switch node {
    case .pane(let id):
      return .leaf(view: RemotePaneLeaf(id: id))
    case .split(let direction, let ratio, let left, let right):
      return .split(
        .init(
          direction: SplitDirection(rawValue: direction) ?? .horizontal, ratio: ratio,
          left: splitNode(left), right: splitNode(right)))
    }
  }

  /// The active group's tree has more than one pane: zoom means something.
  var isActiveGroupSplit: Bool {
    activeGroup.map { Self.paneIDs(in: $0.tree).count > 1 } ?? false
  }

  /// The active group's focused pane (its zoomed pane when zoomed).
  var focusedPaneID: String? {
    guard let group = activeGroup else { return nil }
    return group.zoomedPaneID ?? group.focusedPaneID
  }

  /// The tab a group shows: its focused pane's selected tab (the `splitPerTab` strip's tab).
  func displayedTab(of group: GroupView) -> RemoteClientTab? {
    guard let pane = group.focusedPaneID.flatMap({ panes[$0] }) else { return nil }
    return pane.tabs.first { $0.id == pane.selectedTabID }
  }

  /// The group whose tree holds the pane.
  func groupID(containing paneID: String) -> String? {
    groups.first { Self.paneIDs(in: $0.tree).contains(paneID) }?.id
  }

  /// The shown pane of the active group whose selected tab is this remote content: the pane the
  /// user clicked into when that content's surface took the keyboard.
  func paneID(showing contentID: String) -> String? {
    guard let group = activeGroup else { return nil }
    let shown = group.zoomedPaneID.map { [$0] } ?? Self.paneIDs(in: group.tree)
    return shown.first { paneID in
      guard let pane = panes[paneID] else { return false }
      return pane.tabs.first { $0.id == pane.selectedTabID }?.contentId == contentID
    }
  }

  /// What Select Tab N / Previous / Next picks.
  enum SelectionTarget: Equatable, Sendable {
    case tab(paneID: String, tabID: String)
    case group(String)
  }

  /// The pick of Select Tab N / Previous / Next, as the local window does it: in `splitPerTab` a
  /// group of the strip, else a tab of the focused pane. N is 1-based and clamped to the strip;
  /// previous and next wrap and need two or more. Nil when there is nothing to pick.
  func target(of selection: RemoteTabSelection) -> SelectionTarget? {
    if mode == "splitPerTab" {
      let ids = groups.map(\.id)
      let current = activeGroupID.flatMap { ids.firstIndex(of: $0) }
      return Self.pick(selection, count: ids.count, current: current).map { .group(ids[$0]) }
    }
    guard let paneID = focusedPaneID, let pane = panes[paneID] else { return nil }
    let current = pane.tabs.firstIndex { $0.id == pane.selectedTabID }
    return Self.pick(selection, count: pane.tabs.count, current: current).map {
      .tab(paneID: paneID, tabID: pane.tabs[$0].id)
    }
  }

  private static func pick(_ selection: RemoteTabSelection, count: Int, current: Int?) -> Int? {
    guard count > 0 else { return nil }
    switch selection {
    case .index(let number):
      return min(max(number, 1), count) - 1
    case .previous, .next:
      guard count > 1, let current else { return nil }
      return selection == .next ? (current + 1) % count : (current - 1 + count) % count
    }
  }
}

/// A remote pane as a split-tree leaf, so the remote layout reuses the local focus rules.
nonisolated struct RemotePaneLeaf: Identifiable, Hashable, Sendable {
  let id: String
}
