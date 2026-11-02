import CodevisorCore
import CoreGraphics
import Foundation
import ImageIO
import Observation

@MainActor
@Observable
public final class BotMascotImages {
  public static let shared = BotMascotImages()

  private var images: [ServerBotMascot: CGImage] = [:]
  @ObservationIgnored private var loading: Set<ServerBotMascot> = []

  public func image(for mascot: ServerBotMascot) -> CGImage? {
    images[mascot]
  }

  public func load(_ mascot: ServerBotMascot, from client: any CodevisorServerClienting) async {
    guard images[mascot] == nil, !loading.contains(mascot) else { return }

    loading.insert(mascot)
    defer { loading.remove(mascot) }
    guard let data = try? await client.botMascotImage(mascot) else { return }
    images[mascot] = await Self.decode(data)
  }

  @concurrent
  private nonisolated static func decode(_ data: Data) async -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }
}
