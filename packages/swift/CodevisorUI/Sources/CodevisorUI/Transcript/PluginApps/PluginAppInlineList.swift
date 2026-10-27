import SwiftUI
import TranscriptKit

public struct PluginAppInlineList: View {
  @Environment(\.pluginAppHost) private var host
  let apps: [CodevisorExecutionApp]

  public init(items: [WorkedItem]) {
    apps = TranscriptPluginApps.apps(in: items)
  }

  public var body: some View {
    if let host, !apps.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(apps) { app in
          PluginAppInlineView(model: model(for: app, host: host), host: host)
        }
      }
    }
  }

  private func model(for app: CodevisorExecutionApp, host: PluginAppHost) -> PluginAppInlineModel {
    PluginAppInlineModelCache.shared.model(for: app, chatMachineId: host.session.project.serverId)
  }
}
