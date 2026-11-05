import CodevisorCore
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class BotMascotOpenBots {
  static let shared = BotMascotOpenBots()

  private var openedBy: [UUID: BotMascotStageKey] = [:]

  func isOpen(_ key: BotMascotStageKey) -> Bool {
    openedBy.values.contains(key)
  }

  func open(_ key: BotMascotStageKey, by owner: UUID) {
    guard openedBy[owner] != key else { return }

    openedBy[owner] = key
  }

  func close(by owner: UUID) {
    openedBy[owner] = nil
  }
}

private struct BotMascotOpenModifier: ViewModifier {
  let key: BotMascotStageKey?
  @State private var owner = UUID()

  func body(content: Content) -> some View {
    content
      .onChange(of: key, initial: true) { _, key in mark(key) }
      .onDisappear { BotMascotOpenBots.shared.close(by: owner) }
  }

  private func mark(_ key: BotMascotStageKey?) {
    guard let key else { return BotMascotOpenBots.shared.close(by: owner) }

    BotMascotOpenBots.shared.open(key, by: owner)
  }
}

extension View {
  public func botMascotOpen(_ bot: Bot?) -> some View {
    modifier(BotMascotOpenModifier(key: bot.map(BotMascotStageKey.init)))
  }
}
