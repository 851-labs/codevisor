import CodevisorCore
import SwiftUI

extension ComposerBar {
  func composerTextView(topInset: CGFloat, resizesComposer: Bool) -> ComposerTextView {
    var editor = ComposerTextView(
      text: $text,
      selection: $selection,
      pendingEdit: pendingTextEdit,
      handoffID: textEditorHandoffID,
      handoffRole: textEditorHandoffRole,
      isEditable: textEditorHandoffRole != .none
        || !(controller.isResolvingQuestion || isClearingGoal),
      focusRequest: goalEditFocusRequest ?? initialFocusRequest ?? previewFocusRequest,
      onFocusRequestFulfilled: fulfillFocusRequest,
      onPasteAttachmentEvent: handlePasteAttachmentEvent,
      isComposerExpanded: isExpanded,
      contentHeight: $measuredTextHeight,
      onFocusChange: updateEditorFocus,
      onHardwareReturn: {
        if canSend { submitOrAcceptSlashCommand() }
      },
      onHardwareQueue: hardwareQueueAction,
      topInset: topInset
    )
    guard resizesComposer else { return editor }

    editor.onResizePanChanged = { translation in
      var live = Transaction()
      live.disablesAnimations = true
      withTransaction(live) { panTranslation = translation }
    }
    editor.onResizePanEnded = { translation, velocity in
      endDrag(translation: translation, velocity: velocity)
    }
    editor.onResizePanCancelled = {
      withAnimation(.snappy(duration: 0.28)) { panTranslation = 0 }
    }
    return editor
  }
}
