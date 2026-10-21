import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct ComposerAttachmentThumb: View {
  @Environment(\.quickLook) private var quickLook
  @Environment(\.attachmentImages) private var attachmentImages
  let attachment: ComposerAttachment
  let onRemove: () -> Void
  let onRetry: () -> Void

  @State private var isHovered = false
  @State private var thumbnail: NSImage?

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Group {
        if attachment.hasVisualPreview {
          ZStack {
            RoundedRectangle(cornerRadius: 8)
              .fill(Color.bubbleBackground)
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

      removeButton
        .padding(4)
        .opacity(isHovered ? 1 : 0)
        .allowsHitTesting(isHovered)
    }
    .transcriptSendAttachmentSource(
      id: attachment.uploadedFileID, image: thumbnail, cornerRadius: 8, sentSize: CGSize(width: 56, height: 56)
    )
    .onHover { hovering in
      guard hovering != isHovered else { return }
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { isHovered = hovering }
    }
    .task(id: attachment.fileURL) {
      guard attachment.hasVisualPreview, thumbnail == nil, let fileURL = attachment.fileURL else {
        return
      }
      let isVideo = attachment.isVideo
      let isPDF = attachment.isPDF
      thumbnail = await Task.detached(priority: .userInitiated) {
        await attachmentPreviewImage(fileURL: fileURL, isVideo: isVideo, isPDF: isPDF)
      }.value
    }
    .task(id: attachment.uploadedFileID) {
      guard attachment.fileURL == nil, thumbnail == nil, let uploaded = uploadedPreviewFile else { return }
      thumbnail = await attachmentImages?.image(for: uploaded)?.image
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Attachment \(attachment.name)")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(.default, preview)
    .accessibilityActions {
      Button("Remove", action: onRemove)
      if case .failed = attachment.state {
        Button("Retry Upload", action: onRetry)
      }
    }
  }

  private var uploadedPreviewFile: PreviewFile? {
    guard attachment.isImage, case let .uploaded(ref) = attachment.state else { return nil }
    return PreviewFile(attachment: ref.attachment)
  }

  private func preview() {
    guard let fileURL = attachment.fileURL else { return }
    quickLook?.present(
      .local(
        fileURL: fileURL,
        name: attachment.name,
        mimeType: attachment.mimeType
      ),
      attachmentStore: nil
    )
  }

  @ViewBuilder
  private var stateBadge: some View {
    switch attachment.state {
    case .loading:
      RoundedRectangle(cornerRadius: 8)
        .fill(.black.opacity(0.25))
        .overlay(ProgressView().controlSize(.small))
        .allowsHitTesting(false)
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
                .foregroundStyle(.orange)
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
