import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

@MainActor
struct RemoteAccessSettingsTests {
  nonisolated static let relayURL = "wss://relay.example.invalid/host"

  nonisolated static let configured = RemoteAccessFileStatus(
    presence: .present, enabled: true, lan: true, relayURL: relayURL, hasHostKey: true, hasConnectionKey: true)

  nonisolated static let running = RemoteAccessHostStatus(
    mayHost: true, override: .none, isRunning: true, isRelayConnected: true, lanPort: 4242)

  // MARK: - Reducer

  @Test func taskPollsUntilCancelled() async {
    let clock = TestClock()
    let file = LockIsolated(Self.configured)
    let store = TestStore(initialState: RemoteAccessFeature.State()) {
      RemoteAccessFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0[RemoteAccessClient.self].fileStatus = { file.value }
      $0[RemoteAccessClient.self].hostStatus = { Self.running }
    }
    let task = await store.send(.task)
    await store.receive(\.refreshed) {
      $0.file = Self.configured
      $0.host = Self.running
    }
    file.withValue { $0.lan = false }
    await clock.advance(by: RemoteAccessFeature.pollInterval)
    await store.receive(\.refreshed) {
      $0.file.lan = false
    }
    await task.cancel()
  }

  @Test func togglingEnabledWritesKeepsLANAndRestartsTheHost() async {
    let writes = LockIsolated<[[Bool]]>([])
    let restarts = LockIsolated(0)
    let disabled = {
      var status = Self.configured
      status.enabled = false
      return status
    }()
    let store = TestStore(initialState: RemoteAccessFeature.State(file: Self.configured, host: Self.running)) {
      RemoteAccessFeature()
    } withDependencies: {
      $0[RemoteAccessClient.self].writeFlags = { enabled, lan in writes.withValue { $0.append([enabled, lan]) } }
      $0[RemoteAccessClient.self].restartHost = { restarts.withValue { $0 += 1 } }
      $0[RemoteAccessClient.self].fileStatus = { disabled }
      $0[RemoteAccessClient.self].hostStatus = { .stopped }
    }
    await store.send(.enabledToggled(false)) {
      $0.file.enabled = false
      $0.isApplying = true
    }
    await store.receive(\.applyFinished) {
      $0.isApplying = false
      $0.host = .stopped
    }
    #expect(writes.value == [[false, true]])
    #expect(restarts.value == 1)
  }

  @Test func togglesDuringAnApplyRunOneMoreApplyWithTheLatestState() async {
    let clock = TestClock()
    let writes = LockIsolated<[[Bool]]>([])
    let restarts = LockIsolated(0)
    let onDisk = LockIsolated(Self.configured)
    let store = TestStore(initialState: RemoteAccessFeature.State(file: Self.configured, host: Self.running)) {
      RemoteAccessFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0[RemoteAccessClient.self].writeFlags = { enabled, lan in
        // Each write takes a second, so the next toggles land while it runs.
        try await clock.sleep(for: .seconds(1))
        writes.withValue { $0.append([enabled, lan]) }
        onDisk.withValue {
          $0.enabled = enabled
          $0.lan = lan
        }
      }
      $0[RemoteAccessClient.self].restartHost = { restarts.withValue { $0 += 1 } }
      $0[RemoteAccessClient.self].fileStatus = { onDisk.value }
      $0[RemoteAccessClient.self].hostStatus = { Self.running }
    }
    await store.send(.enabledToggled(false)) {
      $0.file.enabled = false
      $0.isApplying = true
    }
    await store.send(.enabledToggled(true)) {
      $0.file.enabled = true
      $0.isApplyPending = true
    }
    await store.send(.lanToggled(false)) {
      $0.file.lan = false
    }
    // A poll meanwhile must not flip the toggles back to the disk state.
    await store.send(.refreshed(file: onDisk.value, host: Self.running))
    await clock.advance(by: .seconds(1))
    await store.receive(\.applyFinished) {
      $0.isApplyPending = false
    }
    await clock.advance(by: .seconds(1))
    await store.receive(\.applyFinished) {
      $0.isApplying = false
    }
    #expect(writes.value == [[false, true], [true, false]])
    #expect(restarts.value == 2)
    #expect(onDisk.value.enabled && !onDisk.value.lan)
  }

  @Test func togglingIsIgnoredWithoutConfiguration() async {
    let store = TestStore(initialState: RemoteAccessFeature.State()) {
      RemoteAccessFeature()
    }
    await store.send(.enabledToggled(true))
    await store.send(.lanToggled(false))
  }

  @Test func failedWriteShowsTheErrorAndRereadsTheFile() async {
    let restarts = LockIsolated(0)
    let store = TestStore(initialState: RemoteAccessFeature.State(file: Self.configured, host: Self.running)) {
      RemoteAccessFeature()
    } withDependencies: {
      $0[RemoteAccessClient.self].writeFlags = { _, _ in throw RemoteAccessConfigFile.WriteError.writeFailed }
      $0[RemoteAccessClient.self].restartHost = { restarts.withValue { $0 += 1 } }
      $0[RemoteAccessClient.self].fileStatus = { Self.configured }
      $0[RemoteAccessClient.self].hostStatus = { Self.running }
    }
    await store.send(.lanToggled(false)) {
      $0.file.lan = false
      $0.isApplying = true
    }
    let message = RemoteAccessConfigFile.WriteError.writeFailed.localizedDescription
    await store.receive(\.applyFailed) {
      $0.isApplying = false
      $0.errorMessage = message
    }
    await store.receive(\.refreshed) {
      $0.file.lan = true
    }
    #expect(restarts.value == 0)
  }

  @Test func copyingTheKeyShowsFeedbackForAWhile() async {
    let clock = TestClock()
    let store = TestStore(initialState: RemoteAccessFeature.State(file: Self.configured)) {
      RemoteAccessFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0[RemoteAccessClient.self].copyConnectionKey = { true }
    }
    await store.send(.copyConnectionKeyTapped)
    await store.receive(\.connectionKeyCopied) {
      $0.connectionKeyCopied = true
    }
    await clock.advance(by: RemoteAccessFeature.copiedFeedbackDuration)
    await store.receive(\.copiedFeedbackEnded) {
      $0.connectionKeyCopied = false
    }
  }

  @Test func copyingAMissingKeyShowsAnError() async {
    let store = TestStore(initialState: RemoteAccessFeature.State()) {
      RemoteAccessFeature()
    } withDependencies: {
      $0[RemoteAccessClient.self].copyConnectionKey = { false }
    }
    await store.send(.copyConnectionKeyTapped)
    await store.receive(\.connectionKeyCopied) {
      $0.errorMessage = "No connection key found in \(RemoteAccessFeature.clientKeyFileName)."
    }
  }

  // MARK: - Host name

  nonisolated static func configuredFile(hostName: String?) -> RemoteAccessFileStatus {
    var status = configured
    status.hostName = hostName
    return status
  }

  static func state(hostName: String?, draft: String) -> RemoteAccessFeature.State {
    var state = RemoteAccessFeature.State(file: configuredFile(hostName: hostName), host: running)
    state.hostNameDraft = draft
    return state
  }

  @Test func refreshFollowsTheFileButNeverOverwritesTyping() async {
    let store = TestStore(initialState: Self.state(hostName: "Office", draft: "Office")) {
      RemoteAccessFeature()
    }
    await store.send(.refreshed(file: Self.configuredFile(hostName: "Desk"), host: Self.running)) {
      $0.file.hostName = "Desk"
      $0.hostNameDraft = "Desk"
    }
    await store.send(.hostNameDraftChanged("Stud")) {
      $0.hostNameDraft = "Stud"
    }
    await store.send(.refreshed(file: Self.configuredFile(hostName: "Office"), host: Self.running)) {
      $0.file.hostName = "Office"
    }
  }

  @Test func submittingTheSavedNameWritesNothing() async {
    let writes = LockIsolated(0)
    let store = TestStore(initialState: Self.state(hostName: "Office", draft: " Office ")) {
      RemoteAccessFeature()
    } withDependencies: {
      $0[RemoteAccessClient.self].writeHostName = { _ in writes.withValue { $0 += 1 } }
    }
    await store.send(.hostNameSubmitted)
    #expect(writes.value == 0)
  }

  @Test func submittingANewNameWritesItAndRenamesTheHostOnce() async {
    let writes = LockIsolated<[String?]>([])
    let renames = LockIsolated<[String]>([])
    let onDisk = LockIsolated(Self.configuredFile(hostName: "Office"))
    let store = TestStore(initialState: Self.state(hostName: "Office", draft: "  Desk  ")) {
      RemoteAccessFeature()
    } withDependencies: {
      $0[RemoteAccessClient.self].writeHostName = { name in
        writes.withValue { $0.append(name) }
        onDisk.withValue { $0.hostName = name }
      }
      $0[RemoteAccessClient.self].renameHost = { name in renames.withValue { $0.append(name) } }
      $0[RemoteAccessClient.self].computerName = { "Studio Mac" }
      $0[RemoteAccessClient.self].fileStatus = { onDisk.value }
    }
    await store.send(.hostNameSubmitted) {
      $0.hostNameDraft = "Desk"
      $0.isApplying = true
      $0.isSavingHostName = true
      $0.hostNameInFlight = "Desk"
    }
    await store.receive(\.hostNameSaved) {
      $0.isApplying = false
      $0.isSavingHostName = false
      $0.hostNameInFlight = nil
      $0.file.hostName = "Desk"
    }
    #expect(writes.value == ["Desk"])
    #expect(renames.value == ["Desk"])
  }

  @Test func submittingABlankNameRemovesTheKeyAndRenamesToTheComputerName() async {
    let writes = LockIsolated<[String?]>([])
    let renames = LockIsolated<[String]>([])
    let onDisk = LockIsolated(Self.configuredFile(hostName: "Office"))
    let store = TestStore(initialState: Self.state(hostName: "Office", draft: "   ")) {
      RemoteAccessFeature()
    } withDependencies: {
      $0[RemoteAccessClient.self].writeHostName = { name in
        writes.withValue { $0.append(name) }
        onDisk.withValue { $0.hostName = name }
      }
      $0[RemoteAccessClient.self].renameHost = { name in renames.withValue { $0.append(name) } }
      $0[RemoteAccessClient.self].computerName = { "Studio Mac" }
      $0[RemoteAccessClient.self].fileStatus = { onDisk.value }
    }
    await store.send(.hostNameSubmitted) {
      $0.hostNameDraft = ""
      $0.isApplying = true
      $0.isSavingHostName = true
      $0.hostNameInFlight = ""
    }
    await store.receive(\.hostNameSaved) {
      $0.isApplying = false
      $0.isSavingHostName = false
      $0.hostNameInFlight = nil
      $0.file.hostName = nil
    }
    #expect(writes.value == [nil])
    #expect(renames.value == ["Studio Mac"])
  }

  @Test func failedHostNameWriteShowsTheErrorKeepsTheDraftAndDoesNotRename() async {
    let renames = LockIsolated<[String]>([])
    let store = TestStore(initialState: Self.state(hostName: "Office", draft: "Desk")) {
      RemoteAccessFeature()
    } withDependencies: {
      $0[RemoteAccessClient.self].writeHostName = { _ in throw RemoteAccessConfigFile.WriteError.writeFailed }
      $0[RemoteAccessClient.self].renameHost = { name in renames.withValue { $0.append(name) } }
      $0[RemoteAccessClient.self].fileStatus = { Self.configuredFile(hostName: "Office") }
    }
    await store.send(.hostNameSubmitted) {
      $0.isApplying = true
      $0.isSavingHostName = true
      $0.hostNameInFlight = "Desk"
    }
    let message = RemoteAccessConfigFile.WriteError.writeFailed.localizedDescription
    await store.receive(\.hostNameSaveFailed) {
      $0.isApplying = false
      $0.isSavingHostName = false
      $0.hostNameInFlight = nil
      $0.errorMessage = message
    }
    // The next poll keeps the unsaved name in the field.
    await store.send(.refreshed(file: Self.configuredFile(hostName: "Office"), host: Self.running))
    #expect(renames.value.isEmpty)
  }

  @Test func submittingANameWithoutConfigurationDoesNothing() async {
    var state = RemoteAccessFeature.State()
    state.hostNameDraft = "Desk"
    let store = TestStore(initialState: state) {
      RemoteAccessFeature()
    }
    await store.send(.hostNameSubmitted)
  }

  @Test func aToggleDuringANameSaveRunsAfterItAndBothKeysReachTheFile() async throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (config, clientKey) = try Self.writeConfiguredFiles(in: directory)
    let clock = TestClock()
    let renames = LockIsolated<[String]>([])
    var initial = RemoteAccessFeature.State(
      file: RemoteAccessConfigFile.readStatus(configURL: config, clientKeyURL: clientKey), host: Self.running)
    initial.hostNameDraft = "Desk"
    let store = TestStore(initialState: initial) {
      RemoteAccessFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0[RemoteAccessClient.self].writeHostName = { name in
        // The name save takes a second, so the toggle lands while it runs.
        try await clock.sleep(for: .seconds(1))
        try RemoteAccessConfigFile.writeHostName(name, to: config)
      }
      $0[RemoteAccessClient.self].writeFlags = { enabled, lan in
        try RemoteAccessConfigFile.write(enabled: enabled, lan: lan, to: config)
      }
      $0[RemoteAccessClient.self].renameHost = { name in renames.withValue { $0.append(name) } }
      $0[RemoteAccessClient.self].fileStatus = {
        RemoteAccessConfigFile.readStatus(configURL: config, clientKeyURL: clientKey)
      }
      $0[RemoteAccessClient.self].hostStatus = { Self.running }
    }
    await store.send(.hostNameSubmitted) {
      $0.isApplying = true
      $0.isSavingHostName = true
      $0.hostNameInFlight = "Desk"
    }
    await store.send(.lanToggled(false)) {
      $0.file.lan = false
      $0.isApplyPending = true
    }
    await clock.advance(by: .seconds(1))
    await store.receive(\.hostNameSaved) {
      $0.isApplyPending = false
      $0.isSavingHostName = false
      $0.hostNameInFlight = nil
      $0.file.hostName = "Desk"
    }
    await store.receive(\.applyFinished) {
      $0.isApplying = false
    }
    let object = try Self.readObject(config)
    #expect(object["hostName"] as? String == "Desk")
    #expect(object["lan"] as? Bool == false)
    #expect(object["hostKey"] as? String == "dummy-host-key")
    #expect(renames.value == ["Desk"])
  }

  @Test func aNameSubmitDuringAToggleApplyRunsAfterItAndBothKeysReachTheFile() async throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (config, clientKey) = try Self.writeConfiguredFiles(in: directory)
    let clock = TestClock()
    let renames = LockIsolated<[String]>([])
    let store = TestStore(
      initialState: RemoteAccessFeature.State(
        file: RemoteAccessConfigFile.readStatus(configURL: config, clientKeyURL: clientKey), host: Self.running)
    ) {
      RemoteAccessFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0[RemoteAccessClient.self].writeFlags = { enabled, lan in
        // The apply takes a second, so the name submit lands while it runs.
        try await clock.sleep(for: .seconds(1))
        try RemoteAccessConfigFile.write(enabled: enabled, lan: lan, to: config)
      }
      $0[RemoteAccessClient.self].writeHostName = { name in
        try RemoteAccessConfigFile.writeHostName(name, to: config)
      }
      $0[RemoteAccessClient.self].renameHost = { name in renames.withValue { $0.append(name) } }
      $0[RemoteAccessClient.self].fileStatus = {
        RemoteAccessConfigFile.readStatus(configURL: config, clientKeyURL: clientKey)
      }
      $0[RemoteAccessClient.self].hostStatus = { Self.running }
    }
    await store.send(.lanToggled(false)) {
      $0.file.lan = false
      $0.isApplying = true
    }
    await store.send(.hostNameDraftChanged(" Desk ")) {
      $0.hostNameDraft = " Desk "
    }
    await store.send(.hostNameSubmitted) {
      $0.hostNameDraft = "Desk"
      $0.isSavingHostName = true
      $0.pendingHostName = "Desk"
    }
    await clock.advance(by: .seconds(1))
    await store.receive(\.applyFinished) {
      $0.pendingHostName = nil
      $0.hostNameInFlight = "Desk"
    }
    await store.receive(\.hostNameSaved) {
      $0.isApplying = false
      $0.isSavingHostName = false
      $0.hostNameInFlight = nil
      $0.file.hostName = "Desk"
    }
    let object = try Self.readObject(config)
    #expect(object["hostName"] as? String == "Desk")
    #expect(object["lan"] as? Bool == false)
    #expect(object["hostKey"] as? String == "dummy-host-key")
    #expect(renames.value == ["Desk"])
  }

  // MARK: - Config file

  @Test func writeKeepsOtherKeysAndRestrictsTheMode() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appending(path: "remote-access.json")
    let original = #"{"enabled": true, "relayURL": "\#(Self.relayURL)", "hostKey": "dummy-host-key", "extra": 7}"#
    try Data(original.utf8).write(to: config)

    try RemoteAccessConfigFile.write(enabled: false, lan: false, to: config)

    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
    #expect(object["enabled"] as? Bool == false)
    #expect(object["lan"] as? Bool == false)
    #expect(object["relayURL"] as? String == Self.relayURL)
    #expect(object["hostKey"] as? String == "dummy-host-key")
    #expect(object["extra"] as? Int == 7)
    let mode = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(leftovers == ["remote-access.json"])
  }

  @Test func writeRefusesAMissingFile() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appending(path: "remote-access.json")
    #expect(throws: RemoteAccessConfigFile.WriteError.self) {
      try RemoteAccessConfigFile.write(enabled: true, lan: true, to: config)
    }
    #expect(!FileManager.default.fileExists(atPath: config.path))
  }

  @Test func readStatusReportsEachState() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appending(path: "remote-access.json")
    let clientKey = directory.appending(path: "remote-client-key.txt")

    #expect(RemoteAccessConfigFile.readStatus(configURL: config, clientKeyURL: clientKey) == .missing)

    try Data("not json".utf8).write(to: config)
    #expect(RemoteAccessConfigFile.readStatus(configURL: config, clientKeyURL: clientKey).presence == .malformed)

    try Data(#"{"enabled": false, "relayURL": "\#(Self.relayURL)", "hostKey": "dummy"}"#.utf8).write(to: config)
    try Data("relay.example.invalid/dummy-client-key\n".utf8).write(to: clientKey)
    let status = RemoteAccessConfigFile.readStatus(configURL: config, clientKeyURL: clientKey)
    #expect(
      status
        == RemoteAccessFileStatus(
          presence: .present, enabled: false, lan: true, relayURL: Self.relayURL, hasHostKey: true,
          hasConnectionKey: true))
    #expect(status.isConfigured)
    #expect(RemoteAccessConfigFile.connectionKey(from: clientKey) == "relay.example.invalid/dummy-client-key")
  }

  @Test func writeHostNameKeepsOtherKeysRemovesOnBlankAndRestrictsTheMode() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (config, clientKey) = try Self.writeConfiguredFiles(in: directory)

    try RemoteAccessConfigFile.writeHostName("  Office Mac ", to: config)
    var object = try Self.readObject(config)
    #expect(object["hostName"] as? String == "Office Mac")
    #expect(object["enabled"] as? Bool == true)
    #expect(object["lan"] as? Bool == true)
    #expect(object["relayURL"] as? String == Self.relayURL)
    #expect(object["hostKey"] as? String == "dummy-host-key")
    #expect(object["extra"] as? Int == 7)
    let mode = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    #expect(RemoteAccessConfigFile.readStatus(configURL: config, clientKeyURL: clientKey).hostName == "Office Mac")

    try RemoteAccessConfigFile.writeHostName("   ", to: config)
    object = try Self.readObject(config)
    #expect(object["hostName"] == nil)
    #expect(object["hostKey"] as? String == "dummy-host-key")

    try RemoteAccessConfigFile.writeHostName("Desk", to: config)
    try RemoteAccessConfigFile.writeHostName(nil, to: config)
    object = try Self.readObject(config)
    #expect(object["hostName"] == nil)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    #expect(leftovers == ["remote-access.json", "remote-client-key.txt"])
  }

  nonisolated private static func writeConfiguredFiles(in directory: URL) throws -> (config: URL, clientKey: URL) {
    let config = directory.appending(path: "remote-access.json")
    let clientKey = directory.appending(path: "remote-client-key.txt")
    let original =
      #"{"enabled": true, "lan": true, "relayURL": "\#(relayURL)", "hostKey": "dummy-host-key", "extra": 7}"#
    try Data(original.utf8).write(to: config)
    try Data("relay.example.invalid/dummy-client-key\n".utf8).write(to: clientKey)
    return (config, clientKey)
  }

  nonisolated private static func readObject(_ url: URL) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }

  nonisolated private static func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "remote-access-settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
