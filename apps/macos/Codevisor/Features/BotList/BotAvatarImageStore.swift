import AppKit
import CodevisorCore
import Observation

@Observable
final class BotAvatarImageStore {
  static let shared = BotAvatarImageStore()

  private(set) var images: [UUID: NSImage] = [:]
  @ObservationIgnored private let directory = CodevisorAppVariant.applicationSupportURL()
    .appendingPathComponent("BotAvatars", isDirectory: true)

  func image(for botID: UUID) -> NSImage? {
    images[botID]
  }

  func load(_ botID: UUID) async {
    guard images[botID] == nil else { return }

    let file = directory.appendingPathComponent("\(botID.uuidString.lowercased()).png")
    guard let data = await Self.read(file) else { return }
    images[botID] = NSImage(data: data)
  }

  @concurrent
  private nonisolated static func read(_ file: URL) async -> Data? {
    try? Data(contentsOf: file)
  }
}
