import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

extension ComposerCard {
  func resolving(_ question: AnyHashable) -> Binding<Bool> {
    let state = state
    return Binding(
      get: { state.isResolving(question) },
      set: { state.setResolving($0, question: question) }
    )
  }

  func chatChanged(hasSlashToken: Bool) {
    isPickingFiles = false
    isPickingPhotos = false
    if hasSlashToken { controller.refreshCodevisorSkills() }
  }

  var selection: NSRange {
    get { state.selection(in: controller.composerText) }
    nonmutating set { state.select(newValue, in: controller.composerText) }
  }

  var selectionBinding: Binding<NSRange> {
    let state = state
    let controller = controller
    let editor = sendSource
    return Binding(
      get: { state.selection(in: controller.composerText) },
      set: { state.select($0, in: editor.textView?.string ?? controller.composerText) }
    )
  }

  var slashSelection: Int {
    get { state.slashSelection }
    nonmutating set { if state.slashSelection != newValue { state.slashSelection = newValue } }
  }

  var promptHistory: ComposerPromptHistory? {
    get { state.promptHistory }
    nonmutating set { if state.promptHistory != newValue { state.promptHistory = newValue } }
  }

  var isSlashMenuDismissed: Bool {
    get { state.isSlashMenuDismissed }
    nonmutating set { if state.isSlashMenuDismissed != newValue { state.isSlashMenuDismissed = newValue } }
  }

  var didAcceptSubmission: Bool {
    get { state.didAcceptSubmission }
    nonmutating set { if state.didAcceptSubmission != newValue { state.didAcceptSubmission = newValue } }
  }
}
