import Foundation

enum WorkspaceDeckPolicy {
  static let reusesChatPage = UserDefaults.standard.bool(forKey: "workspaceDeck.reusedChatPage")
  static let warmTranscripts = reusesChatPage ? SessionStore.maxIdleControllers : 6
}
