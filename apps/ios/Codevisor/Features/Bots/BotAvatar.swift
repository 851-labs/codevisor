import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotAvatar: View {
  let mascot: ServerBotMascot?
  let serverId: String
  let symbolName: String
  let size: CGFloat

  init(mascot: ServerBotMascot?, serverId: String, symbolName: String, size: CGFloat) {
    self.mascot = mascot
    self.serverId = serverId
    self.symbolName = symbolName
    self.size = size
  }

  init(bot: Bot, size: CGFloat) {
    self.init(mascot: bot.mascot, serverId: bot.serverId, symbolName: bot.symbolName, size: size)
  }

  var body: some View {
    if let mascot {
      BotMascotAvatar(mascot: mascot, serverId: serverId, size: size)
    } else {
      BotSymbolAvatar(symbolName: symbolName, size: size)
    }
  }
}
