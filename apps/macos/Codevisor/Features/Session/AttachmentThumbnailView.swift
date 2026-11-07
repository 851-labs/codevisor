import SwiftUI
import AppKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown

extension PreviewFile {
  var isPDF: Bool {
    mimeType == "application/pdf" || name.lowercased().hasSuffix(".pdf")
  }

  var isVideo: Bool { attachmentIsVideo(name: name, mimeType: mimeType) }

  var hasVisualPreview: Bool { kind == .image || isPDF || isVideo }
}

struct AttachmentThumbnailView: View {
  @Environment(\.openFileDocument) private var openFileDocument
  @Environment(\.quickLook) private var quickLook
  @Environment(\.attachmentImages) private var attachmentImages
  @Environment(\.markdownBlockChrome) private var chrome
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let file: PreviewFile

  @State private var image: NSImage?
  @State private var geometry = AttachmentPreviewGeometryState()

  init(file: PreviewFile) {
    self.file = file
  }

  var body: some View {
    Group {
      if file.hasVisualPreview {
        imageThumb
          .overlay(alignment: .bottomLeading) {
            if file.isPDF {
              PDFBadge()
            }
          }
          .overlay {
            if file.isVideo {
              VideoPlayBadge()
            }
          }
          .overlay {
            AttachmentLoadingOverlay(isLoading: isLoadingPreview)
              .clipShape(shape)
          }
      } else {
        AttachmentFileChip(name: file.name, isLoading: isLoadingPreview, isBubble: chrome == .bubble) {
          preview()
        }
        .transcriptSendAttachmentTarget(
          id: sentFileID, cornerRadius: 8, fill: .bubbleBackground, stroke: Color(nsColor: .separatorColor)
        )
        .attachmentContextMenu(file: file, image: nil, openInNewTab: openInNewTab, quickLook: preview)
      }
    }
    .task(id: AttachmentThumbnailLoadID(file: file, store: attachmentImages)) {
      guard !file.isPendingCapture else { return resolveFallbackGeometry() }
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
    .task(id: AttachmentThumbnailLoadID(file: file, store: attachmentImages)) {
      guard file.hasVisualPreview, attachmentImages != nil else { return }
      try? await Task.sleep(for: .milliseconds(450))
      guard !Task.isCancelled else { return }
      resolveFallbackGeometry()
    }
    .preference(
      key: AttachmentGeometryReadinessPreferenceKey.self,
      value: file.hasVisualPreview && !geometry.isResolved ? 1 : 0
    )
  }

  private var imageThumb: some View {
    let size = thumbnailSize
    return ZStack {
      if file.kind != .image {
        shape.fill(Color.bubbleBackground)
      }
      if let image = image ?? knownImage {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
      } else {
        Image(systemName: file.isVideo ? "video" : "photo")
          .foregroundStyle(.tertiary)
      }
    }
    .frame(width: size.width, height: size.height)
    .clipShape(shape)
    .overlay {
      if file.kind != .image, chrome.drawsFrame {
        shape.strokeBorder(.separator, lineWidth: 1)
      }
    }
    .transcriptSendAttachmentTarget(
      id: sentFileID, cornerRadius: 8, fill: hasCard ? .bubbleBackground : .clear,
      stroke: hasCard ? Color(nsColor: .separatorColor) : .clear
    )
    .contentShape(shape)
    .onTapGesture {
      preview()
    }
    .help(file.name)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Attachment \(file.name)")
    .accessibilityAddTraits([.isImage, .isButton])
    .accessibilityAction(.default, preview)
    .accessibilityValue(isLoadingPreview ? "Loading" : "")
    .attachmentContextMenu(file: file, image: image, openInNewTab: openInNewTab, quickLook: preview)
  }

  private var shape: RoundedRectangle {
    chrome == .bubble ? UserBubbleBackground.shape(for: dynamicTypeSize) : RoundedRectangle(cornerRadius: 8)
  }

  static let maximumSize = CGSize(width: 320, height: 280)

  static func sentSize(aspectRatio: CGFloat?, isPDF: Bool) -> CGSize {
    boundedAttachmentPreviewSize(
      aspectRatio: aspectRatio, maximumSize: maximumSize, fallbackAspectRatio: fallbackAspectRatio(isPDF: isPDF))
  }

  private static func fallbackAspectRatio(isPDF: Bool) -> CGFloat {
    isPDF ? 8.5 / 11.0 : 16.0 / 9.0
  }

  private var thumbnailSize: CGSize {
    boundedAttachmentPreviewSize(
      aspectRatio: geometry.aspectRatio ?? knownAspectRatio,
      maximumSize: Self.maximumSize,
      fallbackAspectRatio: fallbackAspectRatio
    )
  }

  private var knownImage: OSImage? {
    attachmentImages?.memoryPreview(for: file)?.image ?? SentAttachmentThumbnails.image(for: file)
  }

  private var knownAspectRatio: CGFloat? {
    attachmentImages?.memoryPreview(for: file)?.aspectRatio ?? SentAttachmentThumbnails.aspectRatio(for: file)
  }

  private var hasCard: Bool { file.kind != .image }

  private var sentFileID: String? {
    guard case let .attachment(fileId) = file.source else { return nil }
    return fileId
  }

  private var fallbackAspectRatio: CGFloat {
    Self.fallbackAspectRatio(isPDF: file.isPDF)
  }

  private func apply(_ preview: AttachmentPreviewImage) {
    image = preview.image
    geometry.resolve(
      aspectRatio: preview.aspectRatio,
      fallbackAspectRatio: fallbackAspectRatio
    )
  }

  private func resolveFallbackGeometry() {
    guard file.hasVisualPreview else { return }
    geometry.resolve(aspectRatio: nil, fallbackAspectRatio: fallbackAspectRatio)
  }

  private func openInNewTab() {
    _ = openFileDocument?(FileDocumentLocation.target(for: file))
  }

  private var isLoadingPreview: Bool {
    quickLook?.isLoading(QuickLookItem(file)) ?? false
  }

  private func preview() {
    guard !file.isPendingCapture, !isLoadingPreview else { return }
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

struct AttachmentFileChip: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let name: String
  var isLoading = false
  var isBubble = false
  var onTap: (() -> Void)? = nil

  var body: some View {
    HStack(spacing: 6) {
      AttachmentChipIcon(isLoading: isLoading)
      Text(name)
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(.primary)
    }
    .font(.callout)
    .padding(.horizontal, isBubble ? 12 : 10)
    .padding(.vertical, isBubble ? 7 : 0)
    .frame(height: isBubble ? nil : 56)
    .frame(maxWidth: isBubble ? 260 : 200)
    .fixedSize(horizontal: isBubble, vertical: false)
    .background(shape.fill(Color.bubbleBackground))
    .overlay {
      if !isBubble {
        shape.strokeBorder(.separator, lineWidth: 1)
      }
    }
    .contentShape(shape)
    .onTapGesture { onTap?() }
    .help(name)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(onTap == nil ? [] : .isButton)
    .accessibilityAction(.default) { onTap?() }
    .accessibilityValue(isLoading ? "Loading" : "")
  }

  private var shape: RoundedRectangle {
    isBubble ? UserBubbleBackground.shape(for: dynamicTypeSize) : RoundedRectangle(cornerRadius: 8)
  }
}

struct DropToAttachOverlay: View {
  var body: some View {
    ZStack {
      Color.windowBackgroundColor.opacity(0.92)
      RoundedRectangle(cornerRadius: 16)
        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        .foregroundStyle(Color.accentColor.opacity(0.8))
        .padding(16)
      VStack(spacing: 10) {
        Image(systemName: "paperclip")
          .font(.system(size: 30, weight: .medium))
          .foregroundStyle(.secondary)
        Text("Drop to attach")
          .font(.title2.weight(.semibold))
      }
    }
    .allowsHitTesting(false)
    .transition(.opacity)
  }
}

nonisolated func pngData(from imageData: Data) -> Data? {
  guard let bitmap = NSBitmapImageRep(data: imageData) else { return nil }
  return bitmap.representation(using: .png, properties: [:])
}
