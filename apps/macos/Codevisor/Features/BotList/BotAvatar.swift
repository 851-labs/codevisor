import SwiftUI

struct BotAvatar: View {
  let botID: UUID
  let symbolName: String
  let size: CGFloat
  private let images = BotAvatarImageStore.shared

  var body: some View {
    Group {
      if let image = images.image(for: botID) {
        BotPipAvatar(image: image, size: size)
      } else {
        BotSymbolAvatar(symbolName: symbolName, size: size)
      }
    }
    .task(id: botID) { await images.load(botID) }
  }
}
