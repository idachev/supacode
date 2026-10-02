import AppKit

enum AppBuildStamp {
  static let dateKey = "SupacodeBuildDate"
  static let commitKey = "SupacodeBuildCommit"

  /// One About line: local build clock, then the short git SHA.
  nonisolated static func line(date: String, commit: String) -> String {
    "\(date) · \(commit)"
  }

  static func showAboutPanel() {
    let info = Bundle.main.infoDictionary
    let date = Self.shown(info?[dateKey] as? String)
    let commit = Self.shown(info?[commitKey] as? String)
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let credits = NSAttributedString(
      string: line(date: date, commit: commit),
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
        .paragraphStyle: style,
      ]
    )
    NSApp.orderFrontStandardAboutPanel(options: [
      .credits: credits
    ])
  }

  private static func shown(_ value: String?) -> String {
    guard let value, !value.isEmpty else { return "unknown" }
    return value
  }
}
