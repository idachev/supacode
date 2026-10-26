import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// The "Resume agent sessions" sheet: one checkbox row per pending pane.
struct AgentResumePickerView: View {
  let store: StoreOf<AgentResumePickerFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Resume agent sessions")
          .appFont(.title3, weight: .semibold)
        Text(
          "These panes ran a coding agent before the restart. "
            + "The selected ones type and run the agent's resume command in the background."
        )
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      List {
        ForEach(store.rows) { row in
          AgentResumePickerRow(
            row: row,
            isSelected: Binding(
              get: { store.selected.contains(row.id) },
              set: { _ in store.send(.toggleRow(row.id)) }
            )
          )
        }
      }
      .listStyle(.inset)
      .scrollBounceBehavior(.basedOnSize)
      HStack {
        Spacer()
        Button("Not now") {
          store.send(.notNowTapped)
        }
        .keyboardShortcut(.cancelAction)
        .help("Keep these panes lazy; each resumes when you open it (Esc)")
        Button("Resume selected") {
          store.send(.resumeSelectedTapped)
        }
        .keyboardShortcut(.defaultAction)
        .help("Wake the selected panes in the background and run their resume command (Return)")
        .disabled(store.selected.isEmpty)
      }
    }
    .padding(20)
    .frame(minWidth: 480, minHeight: 240)
  }
}

private struct AgentResumePickerRow: View {
  let row: PendingAgentResume
  @Binding var isSelected: Bool

  var body: some View {
    Toggle(isOn: $isSelected) {
      VStack(alignment: .leading, spacing: 2) {
        Text("\(row.repositoryName) / \(row.worktreeName)")
          .appFont(.headline)
        Text(row.tabTitle)
          .appFont(.subheadline)
          .foregroundStyle(.secondary)
        HStack(spacing: 6) {
          Text(row.agent)
          Text(row.shortSessionID)
            .monospaced()
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .toggleStyle(.checkbox)
    .help("Session \(row.sessionID)")
  }
}
