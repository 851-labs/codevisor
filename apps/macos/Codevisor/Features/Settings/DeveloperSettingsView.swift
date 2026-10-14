import CodevisorCore
import CodevisorUI
import SwiftUI

/// Settings ▸ Developer: preferences for people who build or test
/// Codevisor itself: the update channel and feature flags.
struct DeveloperSettingsView: View {
  private enum UpdateChannel: Hashable, CaseIterable {
    case stable, alpha

    var title: String {
      switch self {
      case .stable: "Stable"
      case .alpha: "Alpha"
      }
    }

    var detail: String {
      switch self {
      case .stable: "Tested releases, published when a version is ready."
      case .alpha: "The newest build from main, every 30 minutes. Expect some instability."
      }
    }
  }

  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme

  private var center: UpdateCenter { environment.updateCenter }

  private var channel: UpdateChannel {
    environment.settings.alphaUpdatesEnabled ? .alpha : .stable
  }

  var body: some View {
    Form {
      Section {
        Picker(selection: channelBinding) {
          ForEach(UpdateChannel.allCases, id: \.self) { channel in
            Text(channel.title).tag(channel)
          }
        } label: {
          VStack(alignment: .leading, spacing: 3) {
            Text("Update channel")
            Text(channel.detail)
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .disabled(center.isCheckingForUpdates || center.hasUpdateInFlight)
      } header: {
        Text("App Version")
      }

      Section {
        ForEach(FeatureFlag.allCases) { flag in
          Toggle(isOn: Binding(get: { flag.isEnabled }, set: { flag.isEnabled = $0 })) {
            VStack(alignment: .leading, spacing: 3) {
              Text(flag.title)
              Text(flag.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      } header: {
        Text("Feature Flags")
      }
    }
    .settingsPaneFormStyle(theme)
  }

  private var channelBinding: Binding<UpdateChannel> {
    Binding(
      get: { channel },
      set: { channel in
        environment.setAlphaUpdatesEnabled(channel == .alpha)
        // A different channel means a different list: check it afresh.
        Task { await center.refresh(force: true) }
      }
    )
  }
}
