import SwiftUI

@MainActor
final class BotReplyHandoff {
  static let shared = BotReplyHandoff()
  static let window: TimeInterval = 0.6

  private var shownSessions: Set<ObjectIdentifier> = []
  private var hiddenAt: [ObjectIdentifier: Date] = [:]
  private var handedOff: Set<String> = []

  func note(shown: Bool, for owner: AnyObject) {
    let key = ObjectIdentifier(owner)
    if shown {
      shownSessions.insert(key)
    } else if shownSessions.remove(key) != nil {
      hiddenAt[key] = Date()
    }
  }

  func claim(_ messageID: String, for owner: AnyObject) -> Bool {
    let key = ObjectIdentifier(owner)
    let isLive =
      shownSessions.contains(key) || hiddenAt[key].map { Date().timeIntervalSince($0) < Self.window } == true
    guard isLive else { return false }
    return handedOff.insert(messageID).inserted
  }
}

struct BotReplyEntrance: ViewModifier {
  let messageID: String
  let owner: AnyObject

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isEntering = false

  func body(content: Content) -> some View {
    content
      .opacity(isEntering ? 0 : 1)
      .scaleEffect(isEntering ? 0.55 : 1, anchor: .bottomLeading)
      .onAppear {
        guard !reduceMotion, BotReplyHandoff.shared.claim(messageID, for: owner) else { return }
        isEntering = true
        DispatchQueue.main.async {
          withAnimation(.spring(duration: 0.38, bounce: 0.18)) { isEntering = false }
        }
      }
  }
}
