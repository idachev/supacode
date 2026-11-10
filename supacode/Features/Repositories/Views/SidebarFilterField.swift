import SupacodeSettingsShared
import SwiftUI

/// The text field above the sidebar list that filters repositories, worktrees
/// and branches (rules in `SidebarFilter`). Owns appearance only; the parent
/// places and pads it. Esc runs `onEscape` (clear and focus the terminal).
struct SidebarFilterField: View {
  @Binding var query: String
  var isFocused: FocusState<Bool>.Binding
  /// The effective "Filter Sidebar" shortcut, shown in the tooltip.
  let shortcut: AppShortcut?
  let onEscape: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "line.3.horizontal.decrease")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField("Filter", text: $query, prompt: Text("Filter"))
        .textFieldStyle(.plain)
        .focused(isFocused)
        .onExitCommand(perform: onEscape)
        .help(AppShortcut.helpText("Filter repositories, worktrees and branches", shortcut: shortcut))
        .accessibilityLabel("Filter Sidebar")
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Clear the filter (Esc)")
        .accessibilityLabel("Clear Filter")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(.quinary, in: .rect(cornerRadius: 6))
  }
}
