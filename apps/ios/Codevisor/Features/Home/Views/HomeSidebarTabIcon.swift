import CodevisorCore
import CodevisorUI
import SwiftUI

/// A tab's identity glyph: a chat's live status replaces its harness icon
/// (error → attention → working → unread), everything else shows its kind.
/// Shared by every sidebar layout so tabs look the same wherever they list.
struct HomeSidebarTabIcon: View {
  @Environment(AppEnvironment.self) private var environment

  let row: HomeSidebarTabRow
  let serverId: String
  /// Point size of the kind glyphs and harness artwork.
  var size: CGFloat = 18

  var body: some View {
    if row.status != .idle {
      HomeStatusIndicator(status: row.status)
    } else {
      switch row.icon {
      case let .chat(harnessId, fallbackSymbolName):
        HarnessIconView(harnessId: harnessId, fallbackSymbolName: fallbackSymbolName, size: size)
          .foregroundStyle(.secondary)
      case let .terminal(isAgentOwned):
        symbol(isAgentOwned ? "server.rack" : "terminal")
      case let .browser(favicon):
        if let favicon {
          Image(uiImage: favicon)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
        } else {
          symbol("globe")
        }
      case let .plugin(pluginId, paneType):
        // Plugin artwork comes from its machine; a fixture row has none.
        if environment.machines.machine(for: serverId) != nil {
          PluginIconView(
            pluginId: pluginId,
            paneType: paneType,
            iconPath: "server",
            client: environment.machines.client(for: serverId),
            cacheNamespace: serverId
          )
          .frame(width: size, height: size)
        } else {
          symbol("puzzlepiece.extension")
        }
      case .document:
        symbol("doc.richtext")
      case .newTab:
        symbol("square.dashed")
      }
    }
  }

  private func symbol(_ name: String) -> some View {
    Image(systemName: name)
      .font(.system(size: size, weight: .medium))
      .foregroundStyle(.secondary)
  }
}

extension HomeSidebarTabRow.Icon {
  /// A short kind name for layouts that caption their tabs.
  var kindLabel: String {
    switch self {
    case .chat: "Chat"
    case let .terminal(isAgentOwned): isAgentOwned ? "Agent terminal" : "Terminal"
    case .browser: "Browser"
    case .plugin: "Plugin"
    case .document: "Document"
    case .newTab: "New Tab"
    }
  }
}

extension HomeSessionStatus {
  /// A one-word caption for status pills and inbox buckets.
  var caption: String {
    switch self {
    case .error: "Error"
    case .actionRequired: "Needs you"
    case .unread: "Unread"
    case .inProgress: "Working"
    case .idle: "Idle"
    }
  }

  var tint: Color {
    switch self {
    case .error: .red
    case .actionRequired: .orange
    case .unread: .blue
    case .inProgress: .secondary
    case .idle: .secondary
    }
  }
}
