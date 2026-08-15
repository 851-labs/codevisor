import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct ComposerAttachmentThumb: View {
    @Environment(\.theme) private var theme
    @Environment(\.quickLook) private var quickLook
    let attachment: ComposerAttachment
    let onRemove: () -> Void
    let onRetry: () -> Void

    @State private var isHovered = false
    /// Decoded once per attachment: `NSImage(data:)` in `body` re-decoded the
    /// image on every re-render (every keystroke while the composer holds
    /// attachments).
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.hasVisualPreview {
                    // A tap gesture rather than a Button: buttons add their own
                    // hover/press highlight over the artwork.
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.bubbleBackground)
                        if let image = thumbnail {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: attachment.isVideo ? "video" : "photo")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.separator, lineWidth: 1)
                    )
                    .overlay(alignment: .bottomLeading) {
                        if attachment.isPDF {
                            PDFBadge()
                        }
                    }
                    .overlay {
                        if attachment.isVideo {
                            VideoPlayBadge()
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { preview() }
                    .help(attachment.name)
                } else {
                    AttachmentFileChip(name: attachment.name) { preview() }
                }
            }
            .overlay {
                stateBadge
            }

            // Always mounted and toggled instantly (no animation): any
            // animated change here rebuilds AppKit hover tracking mid-hover,
            // which oscillates the hover state and flickers.
            removeButton
                .padding(4)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
        }
        .onHover { hovering in
            guard hovering != isHovered else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { isHovered = hovering }
        }
        .task(id: attachment.id) {
            guard attachment.hasVisualPreview, thumbnail == nil else { return }
            let data = attachment.localData
            let name = attachment.name
            let mimeType = attachment.mimeType
            let isVideo = attachment.isVideo
            // Decode off the main thread — a pasted screenshot can be many
            // megabytes and the thumb is 56 pt.
            thumbnail = await Task.detached(priority: .userInitiated) {
                await attachmentPreviewImage(
                    data: data,
                    name: name,
                    mimeType: mimeType,
                    isVideo: isVideo
                )
            }.value
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Attachment \(attachment.name)")
    }

    private func preview() {
        quickLook?.present(
            .local(
                data: attachment.localData,
                name: attachment.name,
                mimeType: attachment.mimeType
            ),
            attachmentStore: nil
        )
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch attachment.state {
        case .uploading:
            RoundedRectangle(cornerRadius: 8)
                .fill(.black.opacity(0.25))
                .overlay(ProgressView().controlSize(.small))
                .allowsHitTesting(false)
        case let .failed(reason):
            Button {
                onRetry()
            } label: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black.opacity(0.35))
                    .overlay(
                        VStack(spacing: 2) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(theme.statusWarn)
                            Text("Retry")
                                .font(.caption2)
                                .foregroundStyle(.white)
                        }
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Upload failed: \(reason). Click to retry.")
        case .uploaded:
            EmptyView()
        }
    }

    private var removeButton: some View {
        Button {
            onRemove()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: Typography.IconSize.compact, weight: .bold))
                // Fixed dark-on-light styling (not theme-derived): the button
                // sits on arbitrary image content, so it needs contrast
                // against white screenshots and dark thumbnails alike.
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(.black.opacity(0.78)))
                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Remove attachment")
        .accessibilityLabel("Remove \(attachment.name)")
    }
}
