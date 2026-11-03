import Foundation

extension SessionController {
  public var isEditingQueuedPrompt: Bool { queuedPromptEdit != nil }

  public var editingQueuedPromptID: String? { queuedPromptEdit?.queueItemID }

  public func beginEditingQueuedPrompt(_ item: ServerPromptQueueItem) {
    stashDraftForQueueEdit(of: item.id)
    restoreComposerPrompt(item.text)
    attachments.restore((item.attachments ?? []).map(ComposerAttachment.init(queued:)))
  }

  public func cancelEditingQueuedPrompt() {
    guard let edit = queuedPromptEdit else { return }
    restoreStashedDraft(edit)
  }

  @discardableResult
  public func saveEditedQueuedPrompt() async -> Bool {
    guard let edit = queuedPromptEdit, !isSubmitting else { return false }
    guard let collected = await attachments.collectAttachmentsForSend() else { return false }

    let saved = await storeEditedQueuedPrompt(edit, attachments: collected)
    if saved { restoreStashedDraft(edit) }
    return saved
  }

  private func stashDraftForQueueEdit(of queueItemID: String) {
    guard var edit = queuedPromptEdit else {
      queuedPromptEdit = QueuedPromptEdit(
        queueItemID: queueItemID,
        stashedText: composerPromptText,
        stashedAttachments: attachments.items
      )
      return
    }
    edit.queueItemID = queueItemID
    queuedPromptEdit = edit
  }

  private func storeEditedQueuedPrompt(_ edit: QueuedPromptEdit, attachments: [Attachment]) async -> Bool {
    guard queuedPrompts.contains(where: { $0.id == edit.queueItemID }) else {
      return await requeueEditedPrompt(attachments: attachments)
    }
    return await updateQueuedPrompt(id: edit.queueItemID, text: composerPromptText, attachments: attachments)
  }

  private func requeueEditedPrompt(attachments: [Attachment]) async -> Bool {
    guard let model else { return false }
    await model.send(UserMessage(text: composerPromptText, attachments: attachments), delivery: .queue)
    return true
  }

  private func restoreStashedDraft(_ edit: QueuedPromptEdit) {
    queuedPromptEdit = nil
    restoreComposerPrompt(edit.stashedText)
    attachments.restoreDraft(edit.stashedAttachments)
  }
}
