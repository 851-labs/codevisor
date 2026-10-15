import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarTabIcon: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.backgroundProminence) private var backgroundProminence

  let row: HomeSidebarTabRow
  let serverId: String
  @ScaledMetric(relativeTo: .body) private var size: CGFloat = 17

  var body: some View {
    if row.status != .idle {
      HomeStatusIndicator(status: row.status)
    } else {
      switch row.icon {
      case let .chat(harnessId, fallbackSymbolName):
        HarnessIconView(harnessId: harnessId, fallbackSymbolName: fallbackSymbolName, size: size)
          .foregroundStyle(glyphStyle)
      case .terminal:
        symbol("terminal")
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
      case .screenSharing:
        symbol("display")
      case .simulator:
        symbol("iphone")
      case .review:
        symbol("plusminus")
      case .document:
        FileIcon(path: row.title, size: size)
      case .newTab:
        symbol("square.dashed")
      }
    }
  }

  private func symbol(_ name: String) -> some View {
    Image(systemName: name)
      .foregroundStyle(glyphStyle)
  }

  private var glyphStyle: AnyShapeStyle {
    backgroundProminence == .increased ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)
  }
}

extension HomeSessionStatus {
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
