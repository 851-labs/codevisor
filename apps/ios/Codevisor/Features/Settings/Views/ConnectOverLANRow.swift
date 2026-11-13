import CodevisorCore
import SwiftUI
import UIKit

struct ConnectOverLANRow: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.scenePhase) private var scenePhase
  @State private var monitor = LocalNetworkPermissionMonitor()

  var body: some View {
    Group {
      if !environment.hasRequestedLocalNetworkAccess {
        LabeledContent("Connect over LAN") {
          Button("Set Up…") { environment.setLocalNetworkAccess(.requested) }
        }
      } else if isOn, case .blocked = monitor.status {
        LocalNetworkBlockedRow()
      } else {
        Toggle("Connect over LAN", isOn: isOnBinding)
      }
    }
    .task(id: isOn && scenePhase == .active) {
      guard isOn, scenePhase == .active else { return }
      await monitor.watch(localServer: nil)
    }
  }

  private var isOn: Bool {
    environment.localNetworkAccess == .requested
  }

  private var isOnBinding: Binding<Bool> {
    Binding(
      get: { isOn },
      set: { environment.setLocalNetworkAccess($0 ? .requested : .deferred) }
    )
  }
}

private struct LocalNetworkBlockedRow: View {
  @Environment(\.openURL) private var openURL

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text("Connect over LAN")
        Text("Turn on Local Network for Codevisor in Settings.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Open Settings", action: openAppSettings)
        .buttonStyle(.borderless)
    }
  }

  private func openAppSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    openURL(url)
  }
}
