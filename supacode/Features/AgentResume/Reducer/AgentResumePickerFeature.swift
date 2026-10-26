import ComposableArchitecture
import Foundation

/// The "Resume agent sessions" sheet: the pending agent resumes after a restart,
/// each with a checkbox. `AppFeature` keeps `rows` in sync with its live pending
/// list and maps the delegate to the background wake.
@Reducer
struct AgentResumePickerFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    let id: UUID
    var rows: IdentifiedArrayOf<PendingAgentResume>
    var selected: Set<ContentID>
  }

  enum Action: Equatable {
    case toggleRow(ContentID)
    case resumeSelectedTapped
    case notNowTapped
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    /// The ticked rows, in row order.
    case resumeRequested([ContentID])
  }

  @Dependency(\.dismiss) private var dismiss

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .toggleRow(let id):
        if state.selected.contains(id) {
          state.selected.remove(id)
        } else {
          state.selected.insert(id)
        }
        return .none

      case .resumeSelectedTapped:
        let ids = state.rows.ids.filter(state.selected.contains)
        return .concatenate(
          .send(.delegate(.resumeRequested(ids))),
          .run { _ in await dismiss() }
        )

      case .notNowTapped:
        return .run { _ in await dismiss() }

      case .delegate:
        return .none
      }
    }
  }
}
