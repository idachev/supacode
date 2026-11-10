import Clocks
import ComposableArchitecture
import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

/// The `worktree.new` rules that need no live app store: request checks, the
/// repository check, the bounded wait (`RemoteHostRouter.runWorktreeNew`) and
/// the reply frames.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteAccessWorktreeNewTests {
  private nonisolated static let worktreeID = WorktreeID("/tmp/repo/feature-x")
  private nonisolated static let firstTab = RemoteWorktreeNewTab(tabId: "tab-1", contentId: "content-1")
  fileprivate nonisolated static let pendingID = WorktreeID("pending:remote-1")

  // MARK: - Request

  private static func resolve(_ json: String) throws -> Result<RemoteWorktreeNewRequest, RemoteWorktreeNewRejection> {
    let message = try #require(RemoteJSON.decodeInbound(Data(json.utf8)))
    return RemoteWorktreeNewRequest.resolve(message)
  }

  @Test func aRequestIsDecodedAndItsNameTrimmed() throws {
    let message = try #require(
      RemoteJSON.decodeInbound(
        Data(#"{"t":"worktree.new","id":7,"repositoryId":"/r","name":"  feature-x \n","cols":80,"rows":24}"#.utf8)))
    #expect(message.id == 7)
    #expect(message.cols == RemoteLenientInt(80))
    #expect(
      RemoteWorktreeNewRequest.resolve(message)
        == .success(RemoteWorktreeNewRequest(repositoryID: "/r", name: "feature-x")))
  }

  @Test func theNameIsRequired() throws {
    #expect(try Self.resolve(#"{"t":"worktree.new","id":7,"repositoryId":"/r"}"#) == .failure(.missingName))
    #expect(try Self.resolve(#"{"t":"worktree.new","id":7,"repositoryId":"/r","name":""}"#) == .failure(.missingName))
    #expect(
      try Self.resolve(#"{"t":"worktree.new","id":7,"repositoryId":"/r","name":"  \t "}"#) == .failure(.missingName))
    #expect(try Self.resolve(#"{"t":"worktree.new","id":7,"repositoryId":"/r","name":null}"#) == .failure(.missingName))
    #expect(RemoteWorktreeNewRejection.missingName.code == "worktree_invalid")
    #expect(RemoteWorktreeNewRejection.missingName.message == "worktree.new needs a branch name")
  }

  @Test func aFieldThatIsNotAStringKeepsTheRequestAnswerable() throws {
    // A bad field must not drop the message: the request still gets an error with its id.
    let message = try #require(
      RemoteJSON.decodeInbound(Data(#"{"t":"worktree.new","id":7,"repositoryId":"/r","name":42}"#.utf8)))
    #expect(message.id == 7)
    #expect(message.name == RemoteLenientString(nil))
    #expect(RemoteWorktreeNewRequest.resolve(message) == .failure(.missingName))
    let listID = #"{"t":"worktree.new","id":7,"repositoryId":["/r"],"name":"x"}"#
    #expect(try Self.resolve(listID) == .failure(.missingRepository))
    #expect(try Self.resolve(#"{"t":"worktree.new","id":7,"name":"x"}"#) == .failure(.missingRepository))
    #expect(RemoteWorktreeNewRejection.missingRepository.message == "worktree.new needs a repositoryId")
  }

  @Test func aNameOverTwoHundredBytesIsRefused() {
    func resolve(_ name: String) -> Result<RemoteWorktreeNewRequest, RemoteWorktreeNewRejection> {
      RemoteWorktreeNewRequest.resolve(
        RemoteInboundMessage(
          t: "worktree.new", id: 1, repositoryId: RemoteLenientString("/r"), name: RemoteLenientString(name)))
    }
    let atLimit = String(repeating: "a", count: 200)
    #expect(resolve(atLimit) == .success(RemoteWorktreeNewRequest(repositoryID: "/r", name: atLimit)))
    #expect(resolve(atLimit + "a") == .failure(.nameTooLong))
    // Bytes, not characters: 101 two-byte letters are 202 bytes.
    #expect(resolve(String(repeating: "я", count: 101)) == .failure(.nameTooLong))
    #expect(RemoteWorktreeNewRejection.nameTooLong.code == "worktree_invalid")
  }

  @Test func aCreatingEntryIsTheBusyGuardIgnoringCase() {
    typealias Creation = AppFeature.RemoteWorktreeCreation
    let creations: [WorktreeID: Creation] = [
      WorktreeID("pending:remote-a"): .creating(repositoryID: "/r", name: "feature-x", abandoned: true),
      WorktreeID("pending:remote-b"): .created(worktreeID: WorktreeID("/r/done"), name: "done"),
    ]
    #expect(Creation.isInFlight(repositoryID: "/r", name: "Feature-X", in: creations))
    #expect(!Creation.isInFlight(repositoryID: "/other", name: "feature-x", in: creations))
    #expect(!Creation.isInFlight(repositoryID: "/r", name: "done", in: creations))
    #expect(RemoteWorktreeNewRejection.busy.code == "worktree_busy")
    #expect(RemoteWorktreeNewRejection.busy.message == "a worktree with this branch is already being created")
  }

  // MARK: - Repository check

  @Test func onlyAGitRepositoryNotBeingRemovedTakesAWorktree() {
    #expect(RemoteWorktreeNewRejection.check(found: true, isGitRepository: true, isBeingRemoved: false) == nil)
    #expect(
      RemoteWorktreeNewRejection.check(found: false, isGitRepository: true, isBeingRemoved: false)
        == .unknownRepository)
    #expect(
      RemoteWorktreeNewRejection.check(found: true, isGitRepository: false, isBeingRemoved: false)
        == .notGitRepository)
    #expect(
      RemoteWorktreeNewRejection.check(found: true, isGitRepository: true, isBeingRemoved: true)
        == .repositoryBeingRemoved)
    #expect(RemoteWorktreeNewRejection.unknownRepository.code == "worktree_invalid")
    #expect(RemoteWorktreeNewRejection.notGitRepository.code == "worktree_unsupported")
    #expect(RemoteWorktreeNewRejection.repositoryBeingRemoved.code == "worktree_unsupported")
    #expect(RemoteSnapshotSource.canCreateWorktree(isGitRepository: true, isBeingRemoved: false))
    #expect(!RemoteSnapshotSource.canCreateWorktree(isGitRepository: false, isBeingRemoved: false))
    #expect(!RemoteSnapshotSource.canCreateWorktree(isGitRepository: true, isBeingRemoved: true))
  }

  @Test func listCarriesCanCreateWorktree() throws {
    let repositories = RemoteSnapshotBuilder.build(repositories: [
      .init(id: "git", name: "git", worktrees: [], canCreateWorktree: true),
      .init(id: "folder", name: "folder", worktrees: []),
    ])
    #expect(repositories.map(\.canCreateWorktree) == [true, false])
    let json = try #require(
      try JSONSerialization.jsonObject(with: RemoteJSON.encode(RemoteListMessage(id: 1, repos: repositories)))
        as? [String: Any])
    let repos = try #require(json["repos"] as? [[String: Any]])
    #expect(repos.map { $0["canCreateWorktree"] as? Bool } == [true, false])
  }

  // MARK: - Wait

  /// Test doubles for what the wait reads from the app.
  private final class Probes: Sendable {
    let creation = LockIsolated<AppFeature.RemoteWorktreeCreation?>(
      .creating(repositoryID: "/tmp/repo", name: "feature-x", abandoned: false))
    let firstTab = LockIsolated<RemoteWorktreeNewTab?>(nil)
    let inRoster = LockIsolated(false)
    let openRejection = LockIsolated<RemoteTabNewRejection?>(nil)
    let opened = LockIsolated<[UUID]>([])
    let content = LockIsolated<UUID?>(nil)
    let consumed = LockIsolated(0)
    let abandoned = LockIsolated(0)

    /// The app's entry as a one-entry dictionary, for the `AppFeature` transitions.
    func apply(_ change: (inout [WorktreeID: AppFeature.RemoteWorktreeCreation]) -> Void) {
      // Not `withValue`: its closure is `@Sendable` and `change` is not; the tests are serial.
      let pendingID = RemoteAccessWorktreeNewTests.pendingID
      var creations: [WorktreeID: AppFeature.RemoteWorktreeCreation] = [:]
      creations[pendingID] = creation.value
      change(&creations)
      let updated = creations[pendingID]
      creation.setValue(updated)
    }

    nonisolated deinit {}

    var probes: RemoteWorktreeNewProbes {
      RemoteWorktreeNewProbes(
        creation: { self.creation.value },
        firstTab: { _ in self.firstTab.value },
        openTab: { _ in
          guard self.inRoster.value else { return nil }
          if let rejection = self.openRejection.value { return .failure(rejection) }
          let tabID = UUID()
          self.opened.withValue { $0.append(tabID) }
          return .success(tabID)
        },
        tabContent: { _, _ in self.content.value }
      )
    }
  }

  private func start(_ probes: Probes, isSSH: Bool = false, clock: TestClock<Duration>) -> Task<
    RemoteWorktreeNewOutcome, Never
  > {
    Task { @MainActor in
      await RemoteHostRouter.awaitWorktreeNew(
        isSSH: isSSH, clock: clock, probes: probes.probes,
        consume: {
          probes.consumed.withValue { $0 += 1 }
          probes.creation.setValue(nil)
        },
        abandon: {
          probes.abandoned.withValue { $0 += 1 }
          probes.apply { AppFeature.RemoteWorktreeCreation.abandon(Self.pendingID, in: &$0) }
        })
    }
  }

  @Test func aCreatedWorktreeIsAnsweredWithItsFirstTab() async {
    let clock = TestClock()
    let probes = Probes()
    let wait = start(probes, clock: clock)
    await Task.megaYield()
    probes.creation.setValue(.created(worktreeID: Self.worktreeID, name: "feature-x"))
    await clock.advance(by: .milliseconds(100))
    await Task.megaYield()
    probes.firstTab.setValue(Self.firstTab)
    await clock.advance(by: .milliseconds(100))
    #expect(await wait.value == .created(worktreeID: Self.worktreeID, name: "feature-x", tab: Self.firstTab))
    #expect(probes.consumed.value == 1)
  }

  @Test func aTabThatNeverAppearsIsAnsweredWithoutItAfterTenSeconds() async {
    let clock = TestClock()
    let probes = Probes()
    probes.creation.setValue(.created(worktreeID: Self.worktreeID, name: "feature-x"))
    let wait = start(probes, clock: clock)
    await Task.megaYield()
    await clock.advance(by: RemoteHostRouter.worktreeNewTabTimeout(isSSH: false))
    #expect(await wait.value == .created(worktreeID: Self.worktreeID, name: "feature-x", tab: nil))
    #expect(RemoteHostRouter.worktreeNewTabTimeout(isSSH: false) == .seconds(10))
    #expect(probes.consumed.value == 1)
  }

  @Test func aFailedFirstTabIsAnsweredWithoutItAtOnce() async {
    let clock = TestClock()
    let probes = Probes()
    probes.creation.setValue(.tabFailed(worktreeID: Self.worktreeID, name: "feature-x"))
    let wait = start(probes, clock: clock)
    // No clock advance: a tab failure ends the wait on its first look.
    #expect(await wait.value == .created(worktreeID: Self.worktreeID, name: "feature-x", tab: nil))
  }

  @Test func aTabFailureDuringThePhaseTwoWaitEndsIt() async {
    let clock = TestClock()
    let probes = Probes()
    probes.creation.setValue(.created(worktreeID: Self.worktreeID, name: "feature-x"))
    let wait = start(probes, clock: clock)
    await Task.megaYield()
    probes.creation.setValue(.tabFailed(worktreeID: Self.worktreeID, name: "feature-x"))
    await clock.advance(by: .milliseconds(100))
    #expect(await wait.value == .created(worktreeID: Self.worktreeID, name: "feature-x", tab: nil))
  }

  @Test func anAppFailureIsAnsweredWithItsMessage() async {
    let clock = TestClock()
    let probes = Probes()
    let wait = start(probes, clock: clock)
    await Task.megaYield()
    probes.creation.setValue(
      .failed(message: "Branch name already exists: Choose a different branch name and try again."))
    await clock.advance(by: .milliseconds(100))
    let outcome = await wait.value
    #expect(outcome == .failed(message: "Branch name already exists: Choose a different branch name and try again."))
    #expect(probes.consumed.value == 1)
    let reply = RemoteHostRouter.worktreeNewReply(for: outcome, repositoryID: "/r", requestID: 7)
    #expect(
      reply
        == .error(
          RemoteErrorMessage(
            id: 7, message: "Branch name already exists: Choose a different branch name and try again.",
            code: "worktree_failed")))
  }

  @Test func noOutcomeInTimeTimesOut() async {
    let clock = TestClock()
    let probes = Probes()
    let wait = start(probes, clock: clock)
    await Task.megaYield()
    await clock.advance(by: .seconds(300))
    let outcome = await wait.value
    #expect(outcome == .timedOut)
    // Still running: abandoned, not consumed, so it keeps guarding its name.
    #expect(probes.consumed.value == 0)
    #expect(probes.abandoned.value == 1)
    #expect(probes.creation.value == .creating(repositoryID: "/tmp/repo", name: "feature-x", abandoned: true))
    #expect(
      RemoteHostRouter.worktreeNewReply(for: outcome, repositoryID: "/r", requestID: nil)
        == .error(
          RemoteErrorMessage(
            id: nil,
            message:
              "worktree creation is still running on the Mac; the outcome is unknown and the worktree may "
              + "appear in the list later",
            code: "worktree_timeout")))
  }

  @Test func theTimeoutsKeepEveryReplyWithin310Seconds() {
    #expect(RemoteHostRouter.worktreeNewTimeout(isSSH: false) == .seconds(300))
    #expect(RemoteHostRouter.worktreeNewTimeout(isSSH: true) == .seconds(290))
    #expect(RemoteHostRouter.worktreeNewTabTimeout(isSSH: false) == .seconds(10))
    #expect(RemoteHostRouter.worktreeNewTabTimeout(isSSH: true) == .seconds(20))
    for isSSH in [false, true] {
      #expect(
        RemoteHostRouter.worktreeNewTimeout(isSSH: isSSH) + RemoteHostRouter.worktreeNewTabTimeout(isSSH: isSSH)
          <= .seconds(310))
    }
  }

  @Test func aDisconnectCancelsTheWaitButTheGuardHoldsUntilTheOutcome() async {
    typealias Creation = AppFeature.RemoteWorktreeCreation
    let clock = TestClock()
    let probes = Probes()
    let wait = start(probes, clock: clock)
    await Task.megaYield()
    await clock.advance(by: .seconds(5))
    wait.cancel()
    let outcome = await wait.value
    #expect(outcome == .cancelled)
    #expect(RemoteHostRouter.worktreeNewReply(for: outcome, repositoryID: "/r", requestID: 7) == nil)
    #expect(probes.consumed.value == 0)
    #expect(probes.abandoned.value == 1)
    // Reconnect and retry the same name (any case) while the first creation runs: worktree_busy.
    var creations: [WorktreeID: Creation] = [:]
    creations[Self.pendingID] = probes.creation.value
    #expect(Creation.isInFlight(repositoryID: "/tmp/repo", name: "Feature-X", in: creations))
    // The outcome arrives: the abandoned entry is dropped and the name is free again.
    Creation.settle(Self.pendingID, as: .created(worktreeID: Self.worktreeID, name: "feature-x"), in: &creations)
    #expect(creations.isEmpty)
    #expect(!Creation.isInFlight(repositoryID: "/tmp/repo", name: "Feature-X", in: creations))
  }

  @Test func aDisconnectDuringTheTabWaitIsCancelledToo() async {
    let clock = TestClock()
    let probes = Probes()
    probes.creation.setValue(.created(worktreeID: Self.worktreeID, name: "feature-x"))
    let wait = start(probes, clock: clock)
    await Task.megaYield()
    wait.cancel()
    #expect(await wait.value == .cancelled)
    // Already settled: consumed, nothing left to guard.
    #expect(probes.consumed.value == 1)
    #expect(probes.abandoned.value == 0)
  }

  // MARK: - ssh

  @Test func anSSHWorktreeGetsATabOpenedOnceTheRosterListsIt() async {
    let clock = TestClock()
    let probes = Probes()
    probes.creation.setValue(.created(worktreeID: Self.worktreeID, name: "feature-x"))
    let wait = start(probes, isSSH: true, clock: clock)
    await Task.megaYield()
    await clock.advance(by: .milliseconds(200))
    #expect(probes.opened.value.isEmpty)
    probes.inRoster.setValue(true)
    await clock.advance(by: .milliseconds(100))
    await Task.megaYield()
    let content = UUID()
    probes.content.setValue(content)
    await clock.advance(by: .milliseconds(100))
    let outcome = await wait.value
    // Opened exactly once, however many ticks it waited for its content.
    #expect(probes.opened.value.count == 1)
    let tabID = probes.opened.value.first
    #expect(
      outcome
        == .created(
          worktreeID: Self.worktreeID, name: "feature-x",
          tab: RemoteWorktreeNewTab(tabId: tabID?.uuidString ?? "", contentId: content.uuidString)))
  }

  @Test func anSSHWorktreeTheRosterNeverListsIsAnsweredWithoutATabAfterTwentySeconds() async {
    let clock = TestClock()
    let probes = Probes()
    probes.creation.setValue(.created(worktreeID: Self.worktreeID, name: "feature-x"))
    let wait = start(probes, isSSH: true, clock: clock)
    await Task.megaYield()
    await clock.advance(by: .seconds(20))
    #expect(await wait.value == .created(worktreeID: Self.worktreeID, name: "feature-x", tab: nil))
    #expect(probes.opened.value.isEmpty)
  }

  @Test func anSSHTabTheHostRefusesIsAnsweredWithoutATab() async {
    let clock = TestClock()
    let probes = Probes()
    probes.creation.setValue(.created(worktreeID: Self.worktreeID, name: "feature-x"))
    probes.inRoster.setValue(true)
    probes.openRejection.setValue(.missingWorktree)
    let wait = start(probes, isSSH: true, clock: clock)
    #expect(await wait.value == .created(worktreeID: Self.worktreeID, name: "feature-x", tab: nil))
  }

  @Test func anSSHCreationTimesOutAt290Seconds() async {
    let clock = TestClock()
    let probes = Probes()
    let wait = start(probes, isSSH: true, clock: clock)
    await Task.megaYield()
    await clock.advance(by: .seconds(290))
    #expect(await wait.value == .timedOut)
  }

  // MARK: - Router wiring

  /// A router on a store whose reducer only keeps the remote bookkeeping (no
  /// git): the request inserts `.creating`, abandon and consume as `AppFeature` does.
  private static func makeRouter(clock: TestClock<Duration>) -> (RemoteHostRouter, StoreOf<AppFeature>) {
    let repository = Repository(
      id: "/tmp/repo", rootURL: URL(fileURLWithPath: "/tmp/repo"), name: "repo", worktrees: [])
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [repository]
    let store = Store(initialState: AppFeature.State(repositories: repositories)) {
      Reduce<AppFeature.State, AppFeature.Action> { state, action in
        switch action {
        case .remoteWorktreeNewRequested(let repositoryID, let name, let pendingID):
          state.remoteWorktreeCreations[pendingID] = .creating(
            repositoryID: repositoryID, name: name, abandoned: false)
        case .remoteWorktreeCreationAbandoned(let pendingID):
          AppFeature.RemoteWorktreeCreation.abandon(pendingID, in: &state.remoteWorktreeCreations)
        case .remoteWorktreeCreationConsumed(let pendingID):
          state.remoteWorktreeCreations[pendingID] = nil
        default:
          break
        }
        return .none
      }
    }
    let router = RemoteHostRouter(
      source: RemoteSnapshotSource(store: store, terminalManager: WorktreeTerminalManager(runtime: GhosttyRuntime())),
      hostName: "Mac", hostID: nil, appLabel: nil, clock: clock)
    return (router, store)
  }

  private static func send(_ router: RemoteHostRouter, _ connID: String, id: Int, name: String) {
    let json = #"{"t":"worktree.new","id":\#(id),"repositoryId":"/tmp/repo","name":"\#(name)"}"#
    router.receiveDirect(connID: connID, json: Data(json.utf8))
  }

  @Test func aDisconnectAbandonsTheCreationAndARetryAfterReconnectIsBusy() async throws {
    let clock = TestClock()
    let (router, store) = Self.makeRouter(clock: clock)
    defer { router.stop() }
    let first = LockIsolated<[String]>([])
    router.lanOpened("phone-1") { frame in first.withValue { $0.append(frame) } }
    Self.send(router, "phone-1", id: 7, name: "feature-x")
    let pendingID = try #require(store.remoteWorktreeCreations.keys.first)
    #expect(
      store.remoteWorktreeCreations[pendingID]
        == .creating(repositoryID: "/tmp/repo", name: "feature-x", abandoned: false))
    await Task.megaYield()
    await clock.advance(by: .seconds(1))
    // The phone's socket closes: its wait ends without a reply, the creation keeps its guard.
    router.lanClosed("phone-1")
    await Task.megaYield()
    await Task.megaYield()
    #expect(first.value.isEmpty)
    #expect(
      store.remoteWorktreeCreations[pendingID]
        == .creating(repositoryID: "/tmp/repo", name: "feature-x", abandoned: true))
    // Reconnect and retry the same name in another case while it still runs: worktree_busy at once.
    let second = LockIsolated<[String]>([])
    router.lanOpened("phone-2") { frame in second.withValue { $0.append(frame) } }
    Self.send(router, "phone-2", id: 8, name: "Feature-X")
    let reply = try #require(second.value.first)
    let json = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    #expect(json["t"] as? String == "error")
    #expect(json["id"] as? Int == 8)
    #expect(json["code"] as? String == "worktree_busy")
    #expect(store.remoteWorktreeCreations.count == 1)
  }

  @Test func aRelayConnCloseAbandonsTheCreationToo() async throws {
    let clock = TestClock()
    let (router, store) = Self.makeRouter(clock: clock)
    defer { router.stop() }
    router.receiveDirect(connID: "relay-1", json: Data(#"{"t":"conn.open"}"#.utf8))
    Self.send(router, "relay-1", id: 3, name: "feature-y")
    let pendingID = try #require(store.remoteWorktreeCreations.keys.first)
    await Task.megaYield()
    router.receiveDirect(connID: "relay-1", json: Data(#"{"t":"conn.close"}"#.utf8))
    await Task.megaYield()
    await Task.megaYield()
    #expect(
      store.remoteWorktreeCreations[pendingID]
        == .creating(repositoryID: "/tmp/repo", name: "feature-y", abandoned: true))
  }

  @Test func aWorktreeNewWithAnUnrelatedFieldOfTheWrongTypeIsStillAnswered() throws {
    let message = try #require(
      RemoteJSON.decodeInbound(
        Data(#"{"t":"worktree.new","id":7,"repositoryId":"/r","name":"x","worktreeId":42}"#.utf8)))
    #expect(message.id == 7)
    #expect(
      RemoteWorktreeNewRequest.resolve(message) == .success(RemoteWorktreeNewRequest(repositoryID: "/r", name: "x")))
    // Other types keep the old rule; a non-integer id is still dropped.
    #expect(RemoteJSON.decodeInbound(Data(#"{"t":"tab.new","id":7,"worktreeId":42}"#.utf8)) == nil)
    #expect(
      RemoteJSON.decodeInbound(Data(#"{"t":"worktree.new","id":"7","repositoryId":"/r","name":"x"}"#.utf8)) == nil)
  }

  // MARK: - Reply

  @Test func theReplyCarriesTheWorktreeAndItsTab() throws {
    let reply = RemoteHostRouter.worktreeNewReply(
      for: .created(worktreeID: Self.worktreeID, name: "feature-x", tab: Self.firstTab),
      repositoryID: "/tmp/repo", requestID: 7)
    guard case .worktree(let message) = reply else {
      Issue.record("expected a worktree.new reply")
      return
    }
    let json = try #require(try JSONSerialization.jsonObject(with: RemoteJSON.encode(message)) as? [String: Any])
    #expect(json["t"] as? String == "worktree.new")
    #expect(json["id"] as? Int == 7)
    #expect(json["repositoryId"] as? String == "/tmp/repo")
    #expect(json["worktreeId"] as? String == "/tmp/repo/feature-x")
    #expect(json["name"] as? String == "feature-x")
    #expect(json["tabId"] as? String == "tab-1")
    #expect(json["contentId"] as? String == "content-1")
  }

  @Test func aReplyWithoutATabOmitsBothTabFieldsAndKeepsANullID() throws {
    let message = RemoteWorktreeNewMessage(
      id: nil, repositoryId: "/r", worktreeId: "/r/x", name: "x", tabId: nil, contentId: nil)
    let json = try #require(try JSONSerialization.jsonObject(with: RemoteJSON.encode(message)) as? [String: Any])
    #expect(Set(json.keys) == ["t", "id", "repositoryId", "worktreeId", "name"])
    #expect(json["id"] is NSNull)
  }
}
