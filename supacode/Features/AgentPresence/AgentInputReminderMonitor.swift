import Foundation
import SupacodeSettingsShared

@MainActor
final class AgentInputReminderMonitor {
  struct Terminal {
    let worktreeID: Worktree.ID
    let title: String
    let screen: String?
    let zmxSocket: String?
    let agentHint: SkillAgent?
  }

  struct Ready {
    let worktreeID: Worktree.ID
    let title: String
    let reminder: AgentInputReminder
  }

  private struct Classification {
    let contentID: UUID
    let waitID: UUID
    let task: Task<Void, Never>
  }

  private var waits: [UUID: AgentInputWait] = [:]
  private(set) var ready: [UUID: Ready] = [:]
  private var scanTask: Task<Void, Never>?
  private var classification: Classification?

  nonisolated deinit {}

  func start(
    terminals: @escaping @MainActor () -> [UUID: Terminal]?,
    didScan: @escaping @MainActor () -> Void
  ) {
    guard scanTask == nil else { return }
    scanTask = Task { [weak self] in
      let clock = ContinuousClock()
      while !Task.isCancelled, self != nil {
        if let snapshot = terminals() {
          await self?.scan(snapshot, now: clock.now)
        } else {
          self?.clear()
        }
        didScan()
        do {
          try await clock.sleep(for: .seconds(5))
        } catch { return }
      }
    }
  }

  func stop() {
    scanTask?.cancel()
    scanTask = nil
    clear()
  }

  private func clear() {
    classification?.task.cancel()
    classification = nil
    waits.removeAll()
    ready.removeAll()
  }

  func invalidate(_ contentID: UUID) -> Bool {
    waits[contentID] = nil
    let hadReminder = ready.removeValue(forKey: contentID) != nil
    cancelObsoleteClassification()
    return hadReminder
  }

  private func cancelObsoleteClassification() {
    guard let classification, waits[classification.contentID]?.id != classification.waitID else { return }
    classification.task.cancel()
    self.classification = nil
  }

  private func scan(_ terminals: [UUID: Terminal], now: ContinuousClock.Instant) async {
    let sockets = terminals.compactMap { id, terminal in
      terminal.zmxSocket.map { (id, $0) }
    }
    let screens = await Task.detached(priority: .utility) {
      var result: [UUID: String] = [:]
      for (id, socket) in sockets {
        guard
          let data = ZmxRemoteStream.captureOnce(
            socketPath: socket, format: ZmxIPCFrameEncoder.formatPlain, scrollbackRows: 0, timeoutMilliseconds: 300
          )
        else { continue }
        result[id] = String(decoding: data, as: UTF8.self)  // swiftlint:disable:this optional_data_string_conversion
      }
      return result
    }.value
    guard !Task.isCancelled else { return }

    var next: [UUID: AgentInputWait] = [:]
    var ready: [UUID: Ready] = [:]
    for (id, terminal) in terminals {
      guard let text = terminal.screen ?? screens[id],
        let screen = AgentInputScreen(text, agentHint: terminal.agentHint)
      else { continue }
      let wait: AgentInputWait
      if let previous = waits[id], previous.screen.text == screen.text {
        wait = previous
      } else {
        wait = AgentInputWait(screen: screen, started: now)
      }
      next[id] = wait
      if let reminder = wait.reminder(at: now) {
        ready[id] = Ready(worktreeID: terminal.worktreeID, title: terminal.title, reminder: reminder)
      }
    }
    waits = next
    self.ready = ready
    cancelObsoleteClassification()
    guard classification == nil,
      let (contentID, wait) = waits.filter({ $0.value.needsClassification(at: now) }).min(by: {
        $0.value.started < $1.value.started
      })
    else { return }
    waits[contentID]?.beginClassification()
    let task = Task { [weak self] in
      let agent = await AgentInputClassifier.classify(screen: wait.screen.text)
      guard !Task.isCancelled, let self else { return }
      self.classification = nil
      guard self.waits[contentID]?.id == wait.id else { return }
      self.waits[contentID]?.resolve(as: agent)
    }
    classification = Classification(contentID: contentID, waitID: wait.id, task: task)
  }
}
