import CodevisorCore
import CoreGraphics
import Foundation
import Observation
import OSLog

let botMascotLog = Logger(subsystem: "dev.codevisor.bots", category: "mascot")

@MainActor
@Observable
final class BotMascotStills {
  static let shared = BotMascotStills(
    disk: BotMascotStillDisk(
      root: CodevisorAppVariant.cacheURL().appendingPathComponent("BotMascotStills", isDirectory: true),
      version: BotMascotArtwork.version))

  private var rendered: [BotMascotStill: CGImage] = [:]
  @ObservationIgnored private var fromDisk: [BotMascotStill: CGImage] = [:]
  @ObservationIgnored private var renders: [BotMascotStill: Task<Void, Never>] = [:]
  @ObservationIgnored private let disk: BotMascotStillDisk

  init(disk: BotMascotStillDisk) {
    self.disk = disk
    Task.detached(priority: .background) { disk.removeOtherVersions() }
  }

  func image(for still: BotMascotStill) -> CGImage? {
    if let image = rendered[still] ?? fromDisk[still] { return image }
    guard let image = disk.image(still) else { return nil }

    fromDisk[still] = image
    return image
  }

  func load(_ still: BotMascotStill) async {
    guard image(for: still) == nil else { return }

    let task = renders[still] ?? startRender(still)
    await task.value
  }

  private func startRender(_ still: BotMascotStill) -> Task<Void, Never> {
    let task = Task {
      defer { renders[still] = nil }
      do {
        let image = try await BotMascotStillRenderer.render(still)
        rendered[still] = image
        await Self.save(image, as: still, on: disk)
      } catch {
        botMascotLog.error("Failed to draw a mascot still: \(String(describing: error), privacy: .public)")
      }
    }
    renders[still] = task
    return task
  }

  @concurrent
  private nonisolated static func save(_ image: CGImage, as still: BotMascotStill, on disk: BotMascotStillDisk) async {
    disk.store(image, as: still)
  }
}
