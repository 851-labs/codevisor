import CodevisorCore
import CoreGraphics
import Foundation
import ImageIO
import Observation

@MainActor
@Observable
public final class BotMascotImages {
  public static let shared = BotMascotImages()
  static let keptLoops = 6

  private var frames: [ServerBotMascotArt: BotMascotFrames] = [:]
  @ObservationIgnored private var fetches: [ServerBotMascotArt: Task<Bool, Never>] = [:]
  @ObservationIgnored private var loopOrder: [ServerBotMascotArt] = []

  public func image(for art: ServerBotMascotArt) -> CGImage? {
    frames[art]?.images.first
  }

  public func frames(for art: ServerBotMascotArt) -> BotMascotFrames? {
    frames[art]
  }

  public func load(_ art: ServerBotMascotArt, retrying retry: MachineRetry) async {
    var failures = 0
    while frames[art] == nil {
      guard await fetch(art, from: retry.client()) else { return }
      guard frames[art] == nil else { return }

      failures += 1
      guard await retry.wait(afterFailures: failures) else { return }
    }
  }

  private func fetch(_ art: ServerBotMascotArt, from client: any CodevisorServerClienting) async -> Bool {
    let fetch = fetches[art] ?? startFetch(art, from: client)
    return await fetch.value
  }

  private func startFetch(_ art: ServerBotMascotArt, from client: any CodevisorServerClienting) -> Task<Bool, Never> {
    let fetch = Task {
      defer { fetches[art] = nil }
      do {
        let data = try await client.botMascotArt(art)
        if let decoded = await BotMascotFrames.decode(data) { store(decoded, for: art) }
        return true
      } catch {
        return !CodevisorServerClientError.isRefusal(error)
      }
    }
    fetches[art] = fetch
    return fetch
  }

  private func store(_ decoded: BotMascotFrames, for art: ServerBotMascotArt) {
    frames[art] = decoded
    guard case .loop = art.kind else { return }

    loopOrder.removeAll { $0 == art }
    loopOrder.append(art)
    while loopOrder.count > Self.keptLoops { frames[loopOrder.removeFirst()] = nil }
  }
}
