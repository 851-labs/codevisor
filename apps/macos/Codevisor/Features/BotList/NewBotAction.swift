import SwiftUI

struct NewBotAction: Equatable {
  let perform: @MainActor () -> Void

  static func == (lhs: NewBotAction, rhs: NewBotAction) -> Bool { true }
}

private struct NewBotActionKey: FocusedValueKey {
  typealias Value = NewBotAction
}

extension FocusedValues {
  var newBotAction: NewBotAction? {
    get { self[NewBotActionKey.self] }
    set { self[NewBotActionKey.self] = newValue }
  }
}
