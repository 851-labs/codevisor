import CodevisorCore
import SwiftUI

struct TranscriptEventIcon: View {
  private static let glyphScale: CGFloat = 0.85

  let icon: TranscriptEventIconKind
  let size: CGFloat

  var body: some View {
    Group {
      switch icon {
      case let .symbol(name):
        Image(systemName: name).font(.system(size: size * Self.glyphScale))
      case let .harness(harnessId):
        HarnessGlyph(harnessId: harnessId, fallbackSymbolName: "person.crop.circle", size: size * Self.glyphScale)
      case let .bot(bot):
        TranscriptEventBotIcon(bot: bot, size: size)
      case let .plugin(pluginId):
        TranscriptEventPluginIcon(pluginId: pluginId, size: size)
      }
    }
    .frame(width: size, height: size)
  }
}

private struct TranscriptEventBotIcon: View {
  let bot: Bot
  let size: CGFloat

  var body: some View {
    if let mascot = bot.mascot {
      BotMascotAvatar(mascot: mascot, serverId: bot.serverId, size: size)
    } else {
      Image(systemName: bot.symbolName).font(.system(size: size * 0.85))
    }
  }
}

private struct TranscriptEventPluginIcon: View {
  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  @Environment(\.transcriptController) private var controller
  let pluginId: String
  let size: CGFloat

  var body: some View {
    if let serverId, let machines = environment?.machines {
      PluginIconView(pluginId: pluginId, client: machines.client(for: serverId), cacheNamespace: serverId, side: size)
    } else {
      Image(systemName: "puzzlepiece.extension").font(.system(size: size * 0.85))
    }
  }

  private var serverId: String? { controller?.project.serverId }
}
