import SwiftUI

struct SidebarNavigation {
  let committed: Binding<SidebarSelection?>
  var highlight: SidebarHighlight? = nil

  var shown: SidebarSelection? {
    guard let highlight else { return committed.wrappedValue }
    return highlight.target(over: committed.wrappedValue)
  }

  var selection: Binding<SidebarSelection?> {
    Binding(get: { shown }, set: { go(to: $0) })
  }

  func go(to target: SidebarSelection?) {
    show(target) { committed.wrappedValue = target }
  }

  func show(_ target: SidebarSelection?, then commit: @escaping () -> Void) {
    guard let highlight else {
      commit()
      return
    }
    highlight.show(target, then: commit)
  }

  func cancelPending() {
    highlight?.discard()
  }
}
