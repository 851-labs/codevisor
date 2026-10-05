import TranscriptKit
import CodevisorCore
import CodevisorUI
import SwiftUI
import StreamMarkdown

extension Attachment {
  /// PDFs render like images rather than as generic file chips.
  var isPDF: Bool {
    mimeType == "application/pdf" || name.lowercased().hasSuffix(".pdf")
  }

  var isVideo: Bool { attachmentIsVideo(name: name, mimeType: mimeType) }

  var hasVisualPreview: Bool { kind == .image || isPDF || isVideo }
}

extension PreviewFile {
  var isPDF: Bool {
    mimeType == "application/pdf" || name.lowercased().hasSuffix(".pdf")
  }

  var isVideo: Bool { attachmentIsVideo(name: name, mimeType: mimeType) }

  var hasVisualPreview: Bool { kind == .image || isPDF || isVideo }
}

// MARK: - Transcript thumbnails

/// Aggregates unresolved, layout-affecting attachment geometry through a
/// hosted transcript row. The native presentation gate consumes this before
/// accepting the row's measured height as final.
typealias AttachmentGeometryReadinessPreferenceKey = ContentLayoutReadinessPreferenceKey

/// A rounded thumbnail for an image, PDF, or video attachment in the
/// transcript, or a file chip for other types. Tapping opens Quick Look.
struct AttachmentThumbnailView: View {
  @Environment(\.openFileDocument) private var openFileDocument
  @Environment(\.theme) private var theme
  @Environment(\.attachmentImages) private var attachmentImages
  @Environment(\.quickLook) private var quickLook
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let file: PreviewFile
  var inline: Bool

  @State private var image: UIImage?
  @State private var geometry = AttachmentPreviewGeometryState()

  init(attachment: Attachment, inline: Bool = false) {
    file = PreviewFile(attachment: attachment)
    self.inline = inline
  }

  init(file: PreviewFile, inline: Bool = false) {
    self.file = file
    self.inline = inline
  }

  var body: some View {
    Group {
      if file.hasVisualPreview {
        imageThumb
          .overlay(alignment: .bottomLeading) {
            if file.isPDF { PDFBadge() }
          }
          .overlay {
            if file.isVideo { VideoPlayBadge() }
          }
          .overlay {
            AttachmentLoadingOverlay(isLoading: isLoadingPreview)
              .clipShape(RoundedRectangle(cornerRadius: 8))
          }
      } else {
        fileChip
      }
    }
    // The store is installed by SessionTranscriptView.onAppear. Include
    // its identity in the task key so a thumbnail that first renders with
    // a nil environment store retries as soon as the store is available.
    // SwiftUI already runs this task once per key, so a separate
    // "didLoad" latch would only recreate the original race.
    .task(id: AttachmentThumbnailLoadID(file: file, store: attachmentImages)) {
      guard file.hasVisualPreview, let attachmentImages else { return }
      if let cached = await attachmentImages.cachedPreview(for: file) {
        guard !Task.isCancelled else { return }
        apply(cached)
      }
      let loaded = await attachmentImages.image(for: file)
      guard !Task.isCancelled else { return }
      if let loaded {
        apply(loaded)
      } else {
        resolveFallbackGeometry()
      }
    }
    // The first cold fetch must not keep the whole transcript invisible.
    // Once this deadline wins, lock the fallback frame for this mount;
    // late pixels may appear inside it but can no longer move the rows.
    .task(id: AttachmentThumbnailLoadID(file: file, store: attachmentImages)) {
      guard inline, file.hasVisualPreview, attachmentImages != nil else { return }
      try? await Task.sleep(for: .milliseconds(450))
      guard !Task.isCancelled else { return }
      resolveFallbackGeometry()
    }
    .preference(
      key: AttachmentGeometryReadinessPreferenceKey.self,
      value: inline && file.hasVisualPreview && !geometry.isResolved ? 1 : 0
    )
  }

  private var imageThumb: some View {
    let size = thumbnailSize
    return ZStack {
      if !inline || file.kind != .image {
        RoundedRectangle(cornerRadius: 8)
          .fill(theme.bubbleBackground)
      }
      if let image = image ?? attachmentImages?.memoryPreview(for: file)?.image
        ?? SentAttachmentThumbnails.image(for: file)
      {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
      } else {
        Image(systemName: file.isVideo ? "video" : "photo")
          .foregroundStyle(.tertiary)
      }
    }
    .frame(width: size.width, height: size.height)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay {
      if !inline || file.kind != .image {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(.separator, lineWidth: 1)
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: 8))
    .onTapGesture { preview() }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Attachment \(file.name)")
    .accessibilityAddTraits([.isImage, .isButton])
    .accessibilityValue(isLoadingPreview ? "Loading" : "")
    .attachmentContextMenu(file: file, image: image, openInNewTab: openInNewTab)
  }

  private var thumbnailSize: CGSize {
    guard inline else { return CGSize(width: 56, height: 56) }
    return boundedAttachmentPreviewSize(
      aspectRatio: geometry.aspectRatio,
      maximumSize: CGSize(width: 280, height: 280),
      fallbackAspectRatio: fallbackAspectRatio
    )
  }

  private var fallbackAspectRatio: CGFloat {
    file.isPDF ? 8.5 / 11.0 : 16.0 / 9.0
  }

  private func apply(_ preview: AttachmentPreviewImage) {
    image = preview.image
    geometry.resolve(
      aspectRatio: preview.aspectRatio,
      fallbackAspectRatio: fallbackAspectRatio
    )
  }

  private func resolveFallbackGeometry() {
    guard inline, file.hasVisualPreview else { return }
    geometry.resolve(aspectRatio: nil, fallbackAspectRatio: fallbackAspectRatio)
  }

  private var fileChip: some View {
    fileChipButton.attachmentContextMenu(file: file, image: nil, openInNewTab: openInNewTab)
  }

  private var fileChipButton: some View {
    Button {
      preview()
    } label: {
      HStack(spacing: 6) {
        AttachmentChipIcon(isLoading: isLoadingPreview)
        Text(file.name)
          // At accessibility sizes, let the name reflow to a second
          // line and the chip widen instead of clipping (HIG:
          // minimize truncation as font size increases).
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
          .truncationMode(.middle)
          .foregroundStyle(.primary)
      }
      .font(.callout)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(minHeight: 56)
      .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 200, alignment: .leading)
      .background(theme.bubbleBackground, in: RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(.separator, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .pointerHighlight(RoundedRectangle(cornerRadius: 8))
    .accessibilityLabel(file.name)
    .accessibilityValue(isLoadingPreview ? "Loading" : "")
  }

  private func openInNewTab() {
    _ = openFileDocument?(FileDocumentLocation.target(for: file))
  }

  private var isLoadingPreview: Bool {
    quickLook?.isLoading(QuickLookItem(file)) ?? false
  }

  private func preview() {
    // A second tap while the file is still downloading would only start
    // the same download again.
    guard !isLoadingPreview else { return }
    quickLook?.present(QuickLookItem(file), attachmentStore: attachmentImages)
  }
}

private struct AttachmentThumbnailLoadID: Hashable {
  let fileID: String
  let storeID: ObjectIdentifier?

  init(file: PreviewFile, store: AttachmentImageStore?) {
    fileID = file.id
    storeID = store.map { ObjectIdentifier($0) }
  }
}

// PDFBadge and VideoPlayBadge are shared with the macOS app via CodevisorUI.
