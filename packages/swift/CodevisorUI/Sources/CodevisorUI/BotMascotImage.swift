import CodevisorCore
import SwiftUI

public struct BotMascotImage: View {
  let mascot: ServerBotMascot
  let serverId: String

  @Environment(AppEnvironment.self) private var environment
  @State private var previous: CGImage?
  private let images = BotMascotImages.shared

  public init(mascot: ServerBotMascot, serverId: String) {
    self.mascot = mascot
    self.serverId = serverId
  }

  public var body: some View {
    Group {
      if let image = images.image(for: mascot) ?? previous {
        Image(decorative: image, scale: 1)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
      } else {
        Color.clear
      }
    }
    .task(id: mascot) { await load() }
    .accessibilityHidden(true)
  }

  private func load() async {
    await images.load(mascot, from: environment.machines.client(for: serverId))
    previous = images.image(for: mascot) ?? previous
  }
}
