import CodevisorCore
import SwiftUI

enum ComposerSlimLayout {
  static let fieldSpacing: CGFloat = 10

  static var fieldLeadingInset: CGFloat {
    ComposerSlimAttachMenu.diameter + fieldSpacing
  }

  static func isActive(_ usesSlimComposer: Bool, for controller: SessionController) -> Bool {
    usesSlimComposer && controller.composerQuestion == nil && !controller.isEditingQueuedPrompt
      && !controller.isGoalEditing
  }
}
