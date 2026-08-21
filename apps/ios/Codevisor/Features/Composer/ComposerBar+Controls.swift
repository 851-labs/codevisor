import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

extension ComposerBar {
    var remainingAttachmentSlots: Int {
        max(0, SessionController.maxAttachments - controller.composerAttachments.count)
    }

    /// Routes file and image pasteboard content through the same staging paths
    /// as the attachment menu. The paste delegate consumes these items so it
    /// does not also insert a filename or object-replacement character.
    func handlePastedAttachments(_ pasted: [PastedAttachment]) {
        for item in pasted {
            switch item {
            case let .fileURL(url):
                ComposerAttachmentStaging.stage(pickedURLs: [url], into: controller)
            case let .image(data, suggestedName):
                controller.attachImageData(data, suggestedName: suggestedName)
            }
        }
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
        .disabled(remainingAttachmentSlots == 0)
        .accessibilityLabel("Attach files")
    }

    var sendButton: some View {
        Button {
            submitOrAcceptSlashCommand()
        } label: {
            // Goal creation remains the ordinary composer interaction. Only
            // an existing goal in edit mode uses the save checkmark.
            Image(systemName: controller.isGoalEditing ? "checkmark" : "arrow.up")
                .font(.subheadline.weight(.bold))
                .scaledFrame(width: 30, height: 30, relativeTo: .subheadline)
                .foregroundStyle(canSend ? Color(.systemBackground) : Color.secondary.opacity(0.75))
                .background(
                    Circle().fill(
                        canSend ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.16)
                    )
                )
                .expandedHitTarget(base: 30)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel(controller.isGoalEditing ? "Save goal" : "Send")
    }

    /// An active Goal chip. Goal is entered through `/goal`; this chip only
    /// provides the matching, discoverable way to leave the mode.
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
        .accessibilityLabel("Goal mode on")
        .accessibilityHint("Returns this draft to a regular chat message")
    }

    /// An active Plan chip. Plan is entered through `/plan`; this chip only
    /// provides the matching, discoverable way to return to build mode.
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
        .disabled(controller.isPlanModeUpdatePending)
        .opacity(controller.isPlanModeUpdatePending ? 0.5 : 1)
        .accessibilityLabel("Plan mode on")
        .accessibilityHint("Returns the agent to implementation mode")
    }

    var goalEditCancelButton: some View {
        Button("Cancel") {
            withAnimation(Motion.quick(reduceMotion: reduceMotion)) {
                controller.exitGoalComposer()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isClearingGoal)
        .expandedHitTarget(base: 30)
        .accessibilityHint("Keeps the current goal and restores your chat draft")
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
            .scaledFrame(width: 30, height: 30, relativeTo: .subheadline)
            .expandedHitTarget(base: 30)
        }
        .buttonStyle(.plain)
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

    var stopButton: some View {
        Button {
            Task { await controller.stop() }
        } label: {
            Image(systemName: "stop.fill")
                .font(.caption.weight(.bold))
                .scaledFrame(width: 30, height: 30, relativeTo: .caption)
                .foregroundStyle(.secondary)
                .background(Circle().fill(Color.secondary.opacity(0.16)))
                .expandedHitTarget(base: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop")
    }

    func submitComposer() {
        let outgoing = text
        let isSubmittingGoal = controller.isGoalComposerArmed
        if preservesFocusAfterSend {
            retainsSubmittedTextForPromotion = true
        }
        if !isSubmittingGoal {
            onWillSend?(outgoing)
        }
        controller.composerText = outgoing
        if !preservesFocusAfterSend {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
            )
        }
        setExpanded(false)

        if isSubmittingGoal {
            Task { await controller.submitGoalFromComposer() }
        } else {
            Task { await controller.send() }
        }
    }
}
