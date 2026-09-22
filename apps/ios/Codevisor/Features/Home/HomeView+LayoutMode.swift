import CodevisorCore
import CodevisorUI
import SwiftUI

/// Folding and unfolding iPhone Duo is a size-class change, never an
/// orientation change. Home latches the container from the horizontal size
/// class and carries its navigation across the swap.
extension HomeView {
  func applyLayoutMode(for sizeClass: UserInterfaceSizeClass?) {
    let target: HomeLayoutMode = sizeClass == .regular ? .split : .stack
    guard target != layoutMode else {
      pendingLayoutMode = nil
      return
    }
    // A sheet mid-promotion is reparenting live UIKit views; swap once it
    // has committed or been cancelled (`newChatFlow` clears either way).
    if let flow = newChatFlow, flow.phase != .composing {
      IOSNavigationDiagnostics.record("home.layoutMode.deferred", "target=\(target) phase=\(flow.phase)")
      pendingLayoutMode = target
      return
    }
    commitLayoutMode(target)
  }

  func commitLayoutMode(_ target: HomeLayoutMode) {
    pendingLayoutMode = nil
    guard target != layoutMode else { return }
    let composingSheet = presentedNewChatFlow != nil
    let transition = HomeNavigationState.layoutTransition(
      from: layoutMode,
      to: target,
      path: navigation.path,
      composingSheet: composingSheet,
      sheetServerId: presentedNewChatFlow?.requestedServerId
    )
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      if transition.dismissesNewChatSheet, let flow = newChatFlow {
        // The draft's text and attachments live in the retained draft
        // controller; only the sheet's editor portal is torn down.
        ComposerTextViewHandoffRegistry.cancel(flow.id)
        presentedNewChatFlow = nil
        newChatFlow = nil
        newChatSheetPath = NavigationPath()
        clientPresentationCompletion.complete("new_chat")
      }
      navigation.path = transition.path
      if transition.requestsComposerFocus {
        detailComposerFocusRequest = UUID()
      }
      detailPath = NavigationPath()
      layoutMode = target
    }
    IOSNavigationDiagnostics.record(
      "home.layoutMode",
      "mode=\(target) path=\(navigationPathSummary(navigation.path)) dismissedSheet=\(transition.dismissesNewChatSheet)"
    )
  }
}
