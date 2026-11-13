import CodevisorCore
import CodevisorCoreMac
import SwiftUI

struct ConnectOverLANRow: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var monitor = LocalNetworkPermissionMonitor()

  var body: some View {
    Group {
      if !environment.hasRequestedLocalNetworkAccess {
        LabeledContent("Connect over LAN") {
          Button("Set Up…") { environment.setLocalNetworkAccess(.requested) }
        }
      } else if isOn, let blockedNames {
        LocalNetworkBlockedRow(blockedNames: blockedNames)
      } else {
        Toggle("Connect over LAN", isOn: isOnBinding)
      }
    }
    .task(id: isOn) {
      guard isOn else { return }
      await monitor.watch(localServer: environment.localServerClient)
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

  private var blockedNames: String? {
    guard case let .blocked(app, server) = monitor.status else { return nil }

    let names = [app ? appName : nil, server ? "node" : nil].compactMap(\.self)
    return names.formatted(.list(type: .and))
  }

  private var appName: String {
    let info = Bundle.main.infoDictionary
    return info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? "Codevisor"
  }
}

private struct LocalNetworkBlockedRow: View {
  let blockedNames: String

  var body: some View {
    LabeledContent {
      Button("Open System Settings", action: openPrivacySettings)
    } label: {
      Text("Connect over LAN")
      Text("Turn on \(blockedNames) in System Settings › Privacy & Security › Local Network.")
    }
  }

  private func openPrivacySettings() {
    guard let url = SystemSettingsPane.privacyAndSecurity.url else { return }
    NSWorkspace.shared.open(url)
  }
}
