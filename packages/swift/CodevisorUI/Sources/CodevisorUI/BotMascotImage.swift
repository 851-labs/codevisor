import CodevisorCore
import SwiftUI

public struct BotMascotImage: View {
  let still: BotMascotStill

  @State private var previous: CGImage?
  private let stills = BotMascotStills.shared

  public init(mascot: ServerBotMascot) {
    self.init(BotMascotStill(mascot, framing: .portrait))
  }

  init(_ still: BotMascotStill) {
    self.still = still
  }

  public var body: some View {
    Group {
      if let image = stills.image(for: still) ?? previous {
        Image(decorative: image, scale: 1)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
      } else {
        Color.clear
      }
    }
    .task(id: still) { await load() }
    .accessibilityHidden(true)
  }

  private func load() async {
    await stills.load(still)
    previous = stills.image(for: still) ?? previous
  }
}
