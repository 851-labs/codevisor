import CodevisorCore
import CodevisorUI
import SwiftUI

struct BotAvatar: View {
  let mascot: ServerBotMascot?
  let symbolName: String
  let size: CGFloat

  init(mascot: ServerBotMascot?, symbolName: String, size: CGFloat) {
    self.mascot = mascot
    self.symbolName = symbolName
    self.size = size
  }

  init(bot: Bot, size: CGFloat) {
    self.init(mascot: bot.mascot, symbolName: bot.symbolName, size: size)
  }

  var body: some View {
    if let mascot {
      BotMascotAvatar(mascot: mascot, size: size)
    } else {
      BotSymbolAvatar(symbolName: symbolName, size: size)
    }
  }
}
