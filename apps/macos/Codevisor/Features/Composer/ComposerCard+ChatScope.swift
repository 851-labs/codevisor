import ACPKit
import CodevisorCore
import SwiftUI

extension ComposerCard {
  struct ChatScope: Equatable {
    let chat: ObjectIdentifier
    let question: AnyHashable?
  }

  var chatScope: ChatScope {
    ChatScope(chat: ObjectIdentifier(controller), question: controller.composerQuestion?.questionId)
  }

  func chatScopeChanged(from old: ChatScope, to new: ChatScope) {
    didStartResolvingQuestion = false
    guard old.chat != new.chat else { return }

    selection = NSRange(location: (controller.composerText as NSString).length, length: 0)
    promptHistory = nil
    didAcceptSubmission = false
    slashSelection = 0
    isSlashMenuDismissed = false
  }
}
