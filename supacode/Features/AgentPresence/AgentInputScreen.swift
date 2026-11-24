import Foundation
import SupacodeSettingsShared

/// The current terminal screen, reduced to the portion around the input controls.
nonisolated struct AgentInputScreen: Equatable, Sendable {
  enum Assessment: Equatable, Sendable {
    case waiting(SkillAgent)
    case needsClassification
  }

  let text: String
  let assessment: Assessment

  init?(_ screen: String, agentHint: SkillAgent?) {
    let lines = screen.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    let text = String(lines.suffix(24).joined(separator: "\n").suffix(3_000))
    let controls = lines.suffix(8).joined(separator: "\n").lowercased()
    let lower = text.lowercased()
    guard !controls.isEmpty else { return nil }

    // Match the live menu and its controls together. Old questions and code samples
    // elsewhere on the screen can still contain the same prompt text.
    let cancelsWithEscape = controls.contains("esc to cancel")
    let isChoiceMenu =
      controls.contains(/(?m)^[❯›>]?\h*1[.)]\h+\S/)
      && controls.contains(/(?m)^[❯›>]?\h*2[.)]\h+\S/)
    if cancelsWithEscape, isChoiceMenu,
      lower.contains("would you like to run the following command?")
        || lower.contains("do you want to apply these changes?")
    {
      self.init(text: text, assessment: .waiting(.codex))
    } else if cancelsWithEscape, isChoiceMenu, lower.contains("do you want to proceed?"), controls.contains("yes"),
      controls.contains("no")
    {
      self.init(text: text, assessment: .waiting(.claude))
    } else if cancelsWithEscape,
      controls.contains("tab/arrow keys to navigate"), controls.contains("enter to select")
    {
      self.init(text: text, assessment: .waiting(.claude))
    } else {
      let agentUI =
        controls.contains("shift+tab to cycle") || controls.contains("? for shortcuts")
        || controls.contains("% context left") || controls.contains("gpt-6") || lower.contains("openai codex")
        || lower.contains("claude code") || (cancelsWithEscape && isChoiceMenu)
      let hasQuestion =
        lower.replacing("? for shortcuts", with: "").contains("?")
        || controls.contains("enter to") || controls.contains("please choose")
        || controls.contains("let me know") || controls.contains("i need you to")
      guard agentHint != nil || agentUI, hasQuestion else { return nil }
      self.init(text: text, assessment: .needsClassification)
    }
  }

  private init(text: String, assessment: Assessment) {
    self.text = text
    self.assessment = assessment
  }
}

/// Tracks one unchanged candidate screen. The id travels to remote clients so an open
/// dialog can be cleared or updated without a second dialog for the same wait.
nonisolated struct AgentInputWait: Equatable, Sendable {
  static let reminderDelay: Duration = .seconds(180)
  static let classificationDelay: Duration = .seconds(20)

  let id = UUID()
  let screen: AgentInputScreen
  let started: ContinuousClock.Instant
  private(set) var classificationStarted = false
  private(set) var agent: SkillAgent?

  init(screen: AgentInputScreen, started: ContinuousClock.Instant) {
    self.screen = screen
    self.started = started
    if case .waiting(let agent) = screen.assessment { self.agent = agent }
  }

  func needsClassification(at now: ContinuousClock.Instant) -> Bool {
    screen.assessment == .needsClassification && !classificationStarted
      && started.duration(to: now) >= Self.classificationDelay
  }

  mutating func beginClassification() {
    classificationStarted = true
  }

  mutating func resolve(as agent: SkillAgent?) {
    self.agent = agent
  }

  func reminder(at now: ContinuousClock.Instant) -> AgentInputReminder? {
    guard let agent, started.duration(to: now) >= Self.reminderDelay else { return nil }
    return AgentInputReminder(id: id, agent: agent)
  }
}

nonisolated struct AgentInputReminder: Codable, Equatable, Sendable {
  let id: UUID
  let agent: SkillAgent
}
