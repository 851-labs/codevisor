import SwiftUI

@MainActor
struct SavedInspectorColumn {
  let isShown: Bool
  let savedIsShown: () -> Bool
  let close: () -> Void
  let revert: () -> Void
  var settle: () -> Void = {}

  var binding: Binding<Bool> {
    Binding(get: { isShown }, set: columnReported)
  }

  private func columnReported(_ shown: Bool) {
    guard shown != savedIsShown() else { return settle() }

    if shown {
      revert()
    } else {
      close()
    }
  }
}
