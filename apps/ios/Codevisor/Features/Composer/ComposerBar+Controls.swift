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
            let outgoing = text
            if preservesFocusAfterSend {
                retainsSubmittedTextForPromotion = true
            }
            onWillSend?(outgoing)
            controller.composerText = outgoing
            if !preservesFocusAfterSend {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                )
            }
            setExpanded(false)
            Task { await controller.send() }
        } label: {
            Image(systemName: "arrow.up")
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
        .accessibilityLabel("Send")
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
}
