import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

struct RemoteAccessSettingsView: View {
  let store: StoreOf<RemoteAccessFeature>

  var body: some View {
    Form {
      Section {
        RemoteAccessHostRow(file: store.file, host: store.host)
        if store.host.isRunning, store.file.lan {
          LabeledContent {
            Text(lanStatus)
              .foregroundStyle(.secondary)
          } label: {
            Text("LAN shortcut")
          }
        }
      }
      Section {
        Toggle(isOn: Binding(get: { store.file.enabled }, set: { store.send(.enabledToggled($0)) })) {
          Text("Remote access")
          Text("Lets Supacode Remote on your phone reach this Mac through your relay.")
        }
        .help("Turn the remote access host on or off; applies right away")
        Toggle(isOn: Binding(get: { store.file.lan }, set: { store.send(.lanToggled($0)) })) {
          Text("LAN shortcut")
          Text("A phone on the same network connects to this Mac directly over TLS instead of through the relay.")
        }
        .help("Let phones on this network connect directly; applies right away")
        .disabled(!store.file.enabled)
      } footer: {
        if !store.host.mayHost {
          Text("Changes are saved to the configuration file; this copy of Supacode does not host.")
        }
      }
      .disabled(!store.file.isConfigured)
      Section {
        LabeledContent {
          Text(store.file.relayURL ?? "Not set")
            .appFont(.body, monospaced: true)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
        } label: {
          Text("Relay URL")
        }
        LabeledContent {
          Button(store.connectionKeyCopied ? "Copied" : "Copy Connection Key") {
            store.send(.copyConnectionKeyTapped)
          }
          .help("Copy the phone's connection key to the clipboard, to paste into Supacode Remote")
          .disabled(!store.file.hasConnectionKey)
        } label: {
          Text("Connection key")
          Text("Never shown here; read from \(RemoteAccessFeature.clientKeyFileName) when you copy it.")
        }
        LabeledContent {
          Button("Show in Finder") { store.send(.revealConfigFolderTapped) }
            .help("Reveal remote-access.json and the key files in Finder")
        } label: {
          Text("Configuration")
          Text(Self.configPath)
            .appFont(.subheadline, monospaced: true)
            .textSelection(.enabled)
        }
      } footer: {
        Text(
          """
          Setup, key rotation and protections are in docs/remote-access.md in the Supacode repository. \
          Rotating keys needs a relay deploy, so it is not done here.
          """
        )
      }
      if let errorMessage = store.errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
    .contentMargins(.trailing, 6, for: .scrollIndicators)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("Remote Access")
    .task { await store.send(.task).finish() }
  }

  private var lanStatus: String {
    if let port = store.host.lanPort { return "Listening on port \(String(port))" }
    if !store.file.hasConnectionKey { return "Off: no connection key" }
    return store.host.isLANStarting ? "Starting\u{2026}" : "Not running"
  }

  private static var configPath: String {
    (RemoteAccessConfig.defaultFileURL.path as NSString).abbreviatingWithTildeInPath
  }
}

/// Whether this copy hosts, and how the host is doing.
private struct RemoteAccessHostRow: View {
  let file: RemoteAccessFileStatus
  let host: RemoteAccessHostStatus

  var body: some View {
    LabeledContent {
      Label(state.title, systemImage: state.symbol)
        .foregroundStyle(state.style)
    } label: {
      Text("Status")
      Text(detail)
    }
  }

  private struct Indicator {
    let title: String
    let symbol: String
    let style: Color
  }

  private var state: Indicator {
    switch file.presence {
    case .missing:
      return Indicator(title: "Not configured", symbol: "circle.dashed", style: .secondary)
    case .malformed:
      return Indicator(title: "Unreadable configuration", symbol: "exclamationmark.triangle.fill", style: .orange)
    case .present:
      break
    }
    if !file.isConfigured { return Indicator(title: "Not configured", symbol: "circle.dashed", style: .secondary) }
    if !host.mayHost { return Indicator(title: "Not hosting", symbol: "pause.circle", style: .secondary) }
    if !host.isRunning { return Indicator(title: "Off", symbol: "circle", style: .secondary) }
    if host.isRelayConnected {
      return Indicator(title: "Connected to relay", symbol: "checkmark.circle.fill", style: .green)
    }
    return Indicator(title: "Connecting\u{2026}", symbol: "arrow.triangle.2.circlepath", style: .secondary)
  }

  private var detail: String {
    if file.presence != .present || !file.isConfigured {
      return "Run remote-relay/scripts/gen-keys.mjs to create the keys and the configuration."
    }
    switch host.override {
    case .forcedOn:
      return "SUPACODE_REMOTE_ACCESS=1 makes this copy of Supacode the host."
    case .forcedOff:
      return "SUPACODE_REMOTE_ACCESS=0 keeps this copy of Supacode from hosting."
    case .none:
      return host.mayHost
        ? "This is the installed app, so it hosts remote access."
        : "Only the app installed in Applications hosts; set SUPACODE_REMOTE_ACCESS=1 to force this copy."
    }
  }
}
