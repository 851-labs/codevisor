import CodevisorCore
import SwiftUI

struct BotListActions: Equatable {
  let newBot: (@MainActor () -> Void)?
  let stepBot: @MainActor (Int) -> Void
  let editBot: @MainActor (Bot) -> Void

  static func == (lhs: BotListActions, rhs: BotListActions) -> Bool {
    (lhs.newBot == nil) == (rhs.newBot == nil)
  }
}

private struct BotListActionsKey: FocusedValueKey {
  typealias Value = BotListActions
}

extension FocusedValues {
  var botListActions: BotListActions? {
    get { self[BotListActionsKey.self] }
    set { self[BotListActionsKey.self] = newValue }
  }
}
