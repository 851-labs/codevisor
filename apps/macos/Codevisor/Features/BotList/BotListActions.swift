import CodevisorCore
import SwiftUI

struct BotListActions: Equatable {
  let newBot: (@MainActor () -> Void)?
  let newProject: @MainActor () -> Void
  let stepBot: @MainActor (Int) -> Void
  let editBot: @MainActor (Bot) -> Void
  let archiveBot: (@MainActor () -> Void)?

  static func == (lhs: BotListActions, rhs: BotListActions) -> Bool {
    (lhs.newBot == nil) == (rhs.newBot == nil) && (lhs.archiveBot == nil) == (rhs.archiveBot == nil)
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
