import CodevisorCore
import SwiftUI

public struct BotMascotImage: View {
  let art: ServerBotMascotArt
  let serverId: String

  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  @State private var previous: CGImage?
  private let images = BotMascotImages.shared

  public init(mascot: ServerBotMascot, serverId: String, kind: ServerBotMascotArt.Kind = .portrait) {
    self.art = ServerBotMascotArt(mascot, kind)
    self.serverId = serverId
  }

  public var body: some View {
    Group {
      if let image = images.image(for: art) ?? previous {
        Image(decorative: image, scale: 1)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
      } else {
        Color.clear
      }
    }
    .task(id: art) { await load() }
    .accessibilityHidden(true)
  }

  private func load() async {
    guard let environment else { return }

    await images.load(art, retrying: MachineRetry(machineId: serverId, machines: environment.machines))
    previous = images.image(for: art) ?? previous
  }
}
