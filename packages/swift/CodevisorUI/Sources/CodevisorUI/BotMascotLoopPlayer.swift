import CodevisorCore
import SwiftUI

struct BotMascotLoopPlayer: View {
  let mascot: ServerBotMascot
  let serverId: String
  let loop: ServerBotMascotLoop

  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  private let images = BotMascotImages.shared

  var body: some View {
    Group {
      if let frames = images.frames(for: art) {
        TimelineView(.animation(minimumInterval: frames.frameSeconds)) { context in
          frame(frames.image(at: context.date))
        }
      } else {
        BotMascotImage(mascot: mascot, serverId: serverId, kind: .figure)
      }
    }
    .task(id: art) { await load() }
    .accessibilityHidden(true)
  }

  private func load() async {
    guard let environment else { return }

    await images.load(art, from: environment.machines.client(for: serverId))
  }

  private var art: ServerBotMascotArt {
    ServerBotMascotArt(mascot, .loop(loop))
  }

  @ViewBuilder
  private func frame(_ image: CGImage?) -> some View {
    if let image {
      Image(decorative: image, scale: 1)
        .resizable()
        .interpolation(.high)
        .scaledToFit()
    }
  }
}
