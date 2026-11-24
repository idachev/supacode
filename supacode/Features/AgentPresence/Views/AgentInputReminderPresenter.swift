import AppKit
import SwiftUI

/// One floating dialog at a time, shared by local terminals and Remote Mac windows.
@MainActor
final class AgentInputReminderPresenter {
  static let shared = AgentInputReminderPresenter()

  struct Item: Identifiable {
    let id: UUID
    let agent: String
    let location: String
    let open: () -> Void
  }

  enum Source: Hashable {
    case local
    case remote(ObjectIdentifier)
  }

  private var items: [Source: [Item]] = [:]
  private var dismissed: [UUID] = []
  private var current: UUID?
  private var panel: NSPanel?

  nonisolated deinit {}

  func update(_ source: Source, items: [Item]) {
    self.items[source] = items.isEmpty ? nil : items
    present()
  }

  private func present() {
    let pending = items.values.joined().filter { !dismissed.contains($0.id) }
    if let current, pending.contains(where: { $0.id == current }) { return }
    panel?.orderOut(nil)
    panel = nil
    current = nil
    guard let item = pending.first else { return }

    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
      styleMask: [.titled, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.title = "Agent waiting for input"
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    panel.isRestorable = false
    panel.contentViewController = NSHostingController(
      rootView: AgentInputReminderDialog(
        item: item,
        complete: { [weak self] open in
          guard let self, self.current == item.id else { return }
          self.dismissed.append(item.id)
          if self.dismissed.count > 256 { self.dismissed.removeFirst() }
          if open { item.open() }
          self.present()
        })
    )
    panel.center()
    current = item.id
    self.panel = panel
    panel.orderFrontRegardless()
  }
}

private struct AgentInputReminderDialog: View {
  let item: AgentInputReminderPresenter.Item
  let complete: (Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("\(item.agent) has been waiting for input for three minutes.")
          .font(.headline)
        Text(item.location)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      HStack {
        Spacer()
        Button("Dismiss") { complete(false) }
          .keyboardShortcut(.cancelAction)
          .help("Dismiss this reminder (Esc)")
        Button("Open Terminal") { complete(true) }
          .keyboardShortcut(.defaultAction)
          .help("Open the waiting tab and pane (Return)")
      }
    }
    .padding()
    .frame(width: 360)
  }
}
