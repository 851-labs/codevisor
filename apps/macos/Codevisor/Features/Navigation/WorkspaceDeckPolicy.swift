import Foundation

enum WorkspaceDeckPolicy {
  static let reusesChatPage = isOn("workspaceDeck.reusedChatPage", unlessSetIn: .standard)
  static let warmTranscripts = reusesChatPage ? SessionStore.maxIdleControllers : 6

  static func isOn(_ key: String, unlessSetIn defaults: UserDefaults) -> Bool {
    defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
  }
}
