import SwiftUI

/// The one-line banner over a remote terminal (БН1, БН2): an icon and the text, in system colors
/// and Dynamic Type. It only shows what `RemoteConnectionBanner` decided.
struct RemoteConnectionBannerView: View {
  let kind: RemoteConnectionBanner.Kind
  let text: String

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: symbol)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(text)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .font(.callout)
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
    .accessibilityElement(children: .combine)
  }

  private var symbol: String {
    switch kind {
    case .connecting: "arrow.triangle.2.circlepath"
    case .hostOffline: "desktopcomputer.trianglebadge.exclamationmark"
    case .noConnection: "wifi.slash"
    }
  }
}
