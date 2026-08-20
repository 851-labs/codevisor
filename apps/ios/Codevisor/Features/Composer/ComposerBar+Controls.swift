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
            submitComposer()
        } label: {
            Image(systemName: controller.isGoalComposerArmed ? "checkmark" : "arrow.up")
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
        .accessibilityLabel(controller.isGoalComposerArmed ? "Set goal" : "Send")
    }

    var goalModeButton: some View {
        Button {
            controller.composerText = text
            withAnimation(.snappy(duration: 0.15)) {
                controller.toggleGoalComposer()
            }
        } label: {
            if controller.isGoalComposerArmed {
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
            } else {
                Image(systemName: "target")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .scaledFrame(width: 28, height: 28, relativeTo: .subheadline)
                    .expandedHitTarget(base: 28)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(controller.isGoalComposerArmed ? "Goal mode on" : "Set a goal")
        .accessibilityHint(
            controller.isGoalComposerArmed
                ? "Returns this draft to a regular chat message"
                : "Uses the composer text as a persistent goal"
        )
    }

    /// iOS has no slash-command palette, so Plan needs a visible touch entry
    /// point. At rest it stays compact in the crowded composer toolbar; once
    /// active it becomes a labeled, removable chip like Goal. The expanded
    /// hit target preserves the HIG's 44-point minimum without making the
    /// toolbar itself taller.
    var planModeButton: some View {
        Button {
            Task { await controller.togglePlanMode() }
        } label: {
            if controller.isPlanModeOn {
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
            } else {
                Image(systemName: "map")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .scaledFrame(width: 28, height: 28, relativeTo: .subheadline)
                    .expandedHitTarget(base: 28)
            }
        }
        .buttonStyle(.plain)
        .disabled(controller.isPlanModeUpdatePending)
        .opacity(controller.isPlanModeUpdatePending ? 0.5 : 1)
        .accessibilityLabel(controller.isPlanModeOn ? "Plan mode on" : "Plan mode off")
        .accessibilityHint(
            controller.isPlanModeOn
                ? "Returns the agent to implementation mode"
                : "Asks the agent to create a plan before making changes"
        )
    }

    var goalEditCancelButton: some View {
        Button("Cancel") {
            withAnimation(.snappy(duration: 0.15)) {
                controller.exitGoalComposer()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .expandedHitTarget(base: 30)
        .accessibilityHint("Keeps the current goal and restores your chat draft")
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

    private func submitComposer() {
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
