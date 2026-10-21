import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

struct ComposerPasteFailureNotice: Equatable {
  enum Recovery: Equatable {
    case files
  }

  let message: String
  let recovery: Recovery?

  init(failureMessage: String, kind: Attachment.Kind) {
    if failureMessage.contains("too large to upload") {
      message = failureMessage
    } else if kind == .image {
      message = "Couldn't paste this image. Copy it again or choose it from Photos."
    } else {
      message = "Couldn't paste this file. Copy it again or choose it from Files."
    }
    recovery = kind == .image ? nil : .files
  }

  static let attachmentLimit = Self(
    message: "A message can carry at most \(ComposerAttachments.maxAttachments) attachments.",
    recovery: nil
  )

  private init(message: String, recovery: Recovery?) {
    self.message = message
    self.recovery = recovery
  }

  var actionTitle: String? {
    switch recovery {
    case .files: "Choose File"
    case nil: nil
    }
  }
}

extension ComposerBar {
  var remainingAttachmentSlots: Int {
    max(0, ComposerAttachments.maxAttachments - controller.composerAttachments.count)
  }

  func handlePasteAttachmentEvent(_ event: ComposerPasteEvent) {
    switch event {
    case let .began(id, name, mimeType, kind):
      guard
        controller.attachments.beginLoadingAttachment(
          id: id,
          name: name,
          mimeType: mimeType,
          kind: kind
        )
      else {
        pasteFailureNotice = .attachmentLimit
        return
      }
      pasteFailureNotice = nil
    case let .resolved(id, attachment):
      switch attachment {
      case let .fileURL(url):
        ComposerAttachmentStaging.resolve(
          pastedURL: url,
          attachmentID: id,
          into: controller,
          onFailure: presentPasteFailure
        )
      case let .image(data, suggestedName, mimeType):
        if let message = controller.attachments.resolveLoadingAttachment(
          id: id,
          name: suggestedName,
          mimeType: mimeType,
          kind: .image,
          data: data
        ) {
          presentPasteFailure(message, .image)
        }
      }
    case let .failed(id, message, kind):
      if controller.attachments.discardLoadingAttachment(id: id) {
        presentPasteFailure(message, kind)
      }
    }
  }

  func presentPasteFailure(_ message: String, _ kind: Attachment.Kind) {
    pasteFailureNotice = ComposerPasteFailureNotice(
      failureMessage: message,
      kind: kind
    )
  }

  var attachButton: some View {
    Menu {
      Button {
        isPickingPhotos = true
      } label: {
        Label("Photo Library", systemImage: "photo.on.rectangle")
      }
      if UIImagePickerController.isSourceTypeAvailable(.camera) {
        Button {
          isCapturingPhoto = true
        } label: {
          Label("Take Photo", systemImage: "camera")
        }
      }
      Button {
        isPickingFiles = true
      } label: {
        Label("Choose Files", systemImage: "folder")
      }
    } label: {
      Image(systemName: "paperclip")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .scaledFrame(width: 28, height: 28, relativeTo: .subheadline)
        .expandedHitTarget(base: 28)
    }
    .buttonStyle(.plain)
    .pointerHighlight(Circle())
    .disabled(remainingAttachmentSlots == 0 || controller.isSubmitting)
    .accessibilityLabel("Attach files")
  }

  @ViewBuilder
  var sendButton: some View {
    if offersQueueOnSend {
      Menu {
        Button("Queue Message", systemImage: "text.append") {
          submitComposer(delivery: .queue)
        }
      } label: {
        sendButtonLabel
      } primaryAction: {
        submitOrAcceptSlashCommand()
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .pointerHighlight(Circle())
      .disabled(!canSend)
      .accessibilityLabel("Steer")
      .accessibilityHint(
        controller.isPausedForUpdate
          ? "Codevisor is updating"
          : "Adds your message to the running turn. Touch and hold to queue it instead."
      )
    } else {
      Button {
        submitOrAcceptSlashCommand()
      } label: {
        sendButtonLabel
      }
      .buttonStyle(.plain)
      .pointerHighlight(Circle())
      .disabled(!canSend)
      .accessibilityLabel(sendButtonAccessibilityLabel)
      .accessibilityHint(sendButtonAccessibilityHint)
    }
  }

  private var sendButtonLabel: some View {
    Image(systemName: controller.isGoalEditing || controller.isEditingQueuedPrompt ? "checkmark" : "arrow.up")
      .composerCircleActionLabel(.primary, isEnabled: canSend)
  }

  private var offersQueueOnSend: Bool {
    controller.steersWhileWorking && !controller.isGoalEditing && !controller.isEditingQueuedPrompt
      && slashMatches.isEmpty
  }

  private var sendButtonAccessibilityHint: String {
    if controller.isPausedForUpdate { return "Codevisor is updating" }
    return controller.requiresModelSelection ? "Select a model" : ""
  }

  private var sendButtonAccessibilityLabel: String {
    if controller.isEditingQueuedPrompt { return "Save queued message" }
    return controller.isGoalEditing ? "Save goal" : "Send"
  }

  var queueEditToolbar: some View {
    HStack(spacing: 10) {
      attachButton
      Spacer(minLength: 0)
      HStack(spacing: 6) {
        queueEditCancelButton
        sendButton
      }
    }
  }

  private var queueEditCancelButton: some View {
    Button {
      withAnimation(Motion.quick(reduceMotion: reduceMotion)) {
        controller.cancelEditingQueuedPrompt()
      }
    } label: {
      Image(systemName: "xmark")
        .composerCircleActionLabel(.neutral)
    }
    .buttonStyle(.plain)
    .pointerHighlight(Circle())
    .accessibilityLabel("Cancel editing")
    .accessibilityHint("Keeps the queued message as it was and restores your draft")
  }

  var hardwareQueueAction: (() -> Void)? {
    guard controller.canQueueMessages, !controller.isGoalComposerArmed, !controller.isEditingQueuedPrompt,
      slashMatches.isEmpty
    else { return nil }
    return {
      if canSend { submitComposer(delivery: .queue) }
    }
  }

  var goalModeChip: some View {
    Button {
      controller.composerText = text
      withAnimation(Motion.quick(reduceMotion: reduceMotion)) {
        controller.exitGoalComposer()
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "target")
        Text("Goal")
        Image(systemName: "xmark")
          .font(.caption2.weight(.bold))
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(Color(.systemBackground))
      .padding(.horizontal, 9)
      .scaledFrame(height: 30, relativeTo: .caption)
      .background(Capsule().fill(Color.primary.opacity(0.85)))
      .expandedHitTarget(base: 30)
    }
    .buttonStyle(.plain)
    .pointerHighlight(Capsule())
    .accessibilityLabel("Goal mode on")
    .accessibilityHint("Returns this draft to a regular chat message")
  }

  var planModeChip: some View {
    Button {
      Task { await controller.togglePlanMode() }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "map")
        Text("Plan")
        Image(systemName: "xmark")
          .font(.caption2.weight(.bold))
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(Color(.systemBackground))
      .padding(.horizontal, 9)
      .scaledFrame(height: 30, relativeTo: .caption)
      .background(Capsule().fill(Color.primary.opacity(0.85)))
      .expandedHitTarget(base: 30)
    }
    .buttonStyle(.plain)
    .pointerHighlight(Capsule())
    .disabled(controller.isPlanModeUpdatePending)
    .opacity(controller.isPlanModeUpdatePending ? 0.5 : 1)
    .accessibilityLabel("Plan mode on")
    .accessibilityHint("Returns the agent to implementation mode")
  }

  var goalEditCancelButton: some View {
    composerCancelButton(
      hint: "Keeps the current goal and restores your chat draft",
      isDisabled: isClearingGoal
    ) {
      controller.exitGoalComposer()
    }
  }

  private func composerCancelButton(
    hint: String,
    isDisabled: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button("Cancel") {
      withAnimation(Motion.quick(reduceMotion: reduceMotion), action)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(isDisabled)
    .expandedHitTarget(base: 30)
    .accessibilityHint(hint)
  }

  var clearGoalButton: some View {
    Button(role: .destructive) {
      isConfirmingGoalClear = true
    } label: {
      ZStack {
        Image(systemName: "trash")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.red)
          .opacity(isClearingGoal ? 0 : 1)
        if isClearingGoal {
          ProgressView()
            .controlSize(.small)
            .tint(.red)
        }
      }
      .scaledFrame(
        width: ComposerCardStyle.actionDiameter,
        height: ComposerCardStyle.actionDiameter,
        relativeTo: .subheadline
      )
      .expandedHitTarget(base: 30)
    }
    .buttonStyle(.plain)
    .pointerHighlight(Circle())
    .disabled(isClearingGoal)
    .accessibilityLabel(isClearingGoal ? "Clearing goal" : "Clear goal")
    .accessibilityHint("Stops automatic continuation and keeps the chat history")
  }

  func clearGoalFromComposer() {
    guard !isClearingGoal else { return }
    isClearingGoal = true

    Task {
      let succeeded = await controller.clearGoal()
      isClearingGoal = false
      if succeeded {
        withAnimation(Motion.quick(reduceMotion: reduceMotion)) {
          controller.exitGoalComposer()
        }
      } else {
        goalClearError = controller.errorMessage ?? "The goal could not be cleared."
      }
    }
  }

  var showsSendButton: Bool {
    !controller.canStop || !trimmed.isEmpty
  }

  var stopButton: some View {
    Button {
      Task { await controller.stop() }
    } label: {
      Image(systemName: "stop.fill")
        .composerCircleActionLabel(.secondary)
    }
    .buttonStyle(.plain)
    .pointerHighlight(Circle())
    .accessibilityLabel("Stop")
  }

  func submitComposer(delivery: ServerPromptDelivery = .steer) {
    if controller.isEditingQueuedPrompt {
      controller.composerText = text
      Task { await controller.saveEditedQueuedPrompt() }
      return
    }
    let outgoing = text
    let isSubmittingGoal = controller.isGoalComposerArmed
    IOSNavigationDiagnostics.record(
      "composer.submit",
      "chars=\(outgoing.count) preservesFocus=\(preservesFocusAfterSend) role=\(textEditorHandoffRole)"
    )
    if !isSubmittingGoal {
      onWillSend?(outgoing, delivery)
    }
    controller.composerText = outgoing
    if !preservesFocusAfterSend {
      if textEditorHandoffRole == .promotionSource, !reduceMotion {
        holdsFoldUntilFlight = true
      }
      UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
      )
    }
    setExpanded(false)

    if isSubmittingGoal {
      Task { await controller.submitGoalFromComposer() }
    } else {
      controller.promptClientId = clientControlId?.uuidString.lowercased()
      Task { await controller.send(delivery: delivery) }
    }
  }
}

extension ComposerBar {
  @ViewBuilder
  var pasteFailureRail: some View {
    if let notice = pasteFailureNotice {
      if let recovery = notice.recovery, let actionTitle = notice.actionTitle {
        ComposerNoticeRail(
          notice.message,
          kind: .error,
          actionTitle: actionTitle,
          action: { recoverFromPasteFailure(recovery) },
          onDismiss: { pasteFailureNotice = nil }
        )
        .pasteFailureNoticeMeasurement($pasteFailureNoticeHeight)
      } else {
        ComposerNoticeRail(
          notice.message,
          kind: .error,
          onDismiss: { pasteFailureNotice = nil }
        )
        .pasteFailureNoticeMeasurement($pasteFailureNoticeHeight)
      }
    }
  }

  func recoverFromPasteFailure(_ recovery: ComposerPasteFailureNotice.Recovery) {
    pasteFailureNotice = nil
    switch recovery {
    case .files:
      isPickingFiles = true
    }
  }
}

private extension View {
  func pasteFailureNoticeMeasurement(_ height: Binding<CGFloat>) -> some View {
    onGeometryChange(for: CGFloat.self) {
      $0.size.height
    } action: { measuredHeight in
      height.wrappedValue = measuredHeight
    }
  }
}
