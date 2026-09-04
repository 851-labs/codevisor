import SwiftUI
import AppKit
import CodevisorCore
import CodevisorUI
import UniformTypeIdentifiers

// MARK: - Quick Look presentation

/// What Quick Look is showing: bytes already on hand (composer drafts) or a
/// remote file fetched from the session's server (history or a live path).
enum QuickLookItem: Equatable {
  case local(data: Data, name: String, mimeType: String)
  case remote(source: PreviewFile.Source, name: String, mimeType: String)

  var name: String {
    switch self {
    case let .local(_, name, _): return name
    case let .remote(_, name, _): return name
    }
  }

  var mimeType: String {
    switch self {
    case let .local(_, _, mimeType): return mimeType
    case let .remote(_, _, mimeType): return mimeType
    }
  }
}

extension EnvironmentValues {
  @Entry var quickLook: QuickLookController? = nil
}

// MARK: - Thumbnails

extension Attachment {
  /// PDFs render like images (NSImage/PDFKit handle the data) rather than
  /// as generic file chips.
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

// PDFBadge and VideoPlayBadge are shared with the iOS app via CodevisorUI.

/// A small rounded thumbnail for an image, PDF, or video attachment in the
/// transcript, or a file chip for other types. Every attachment opens with
/// Quick Look.
struct AttachmentThumbnailView: View {
  @Environment(\.theme) private var theme
  @Environment(\.quickLook) private var quickLook
  @Environment(\.attachmentImages) private var attachmentImages
  let file: PreviewFile
  var inline: Bool

  @State private var image: NSImage?
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
            if file.isPDF {
              PDFBadge()
            }
          }
          .overlay {
            if file.isVideo {
              VideoPlayBadge()
            }
          }
      } else {
        AttachmentFileChip(name: file.name) {
          preview()
        }
      }
    }
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
    // A cold fetch must not keep the whole transcript invisible. Once the
    // deadline wins, late pixels can fill the frame but cannot resize it.
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
    // A tap gesture rather than a Button: buttons add their own
    // hover/press highlight over the artwork.
    return ZStack {
      RoundedRectangle(cornerRadius: 8)
        .fill(theme.bubbleBackground)
      if let image {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
      } else {
        Image(systemName: file.isVideo ? "video" : "photo")
          .foregroundStyle(.tertiary)
      }
    }
    .frame(width: size.width, height: size.height)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(.separator, lineWidth: 1)
    )
    .contentShape(RoundedRectangle(cornerRadius: 8))
    .onTapGesture {
      preview()
    }
    .help(file.name)
    .accessibilityLabel("Attachment \(file.name)")
    .accessibilityAddTraits(.isButton)
  }

  private var thumbnailSize: CGSize {
    guard inline else { return CGSize(width: 56, height: 56) }
    return boundedAttachmentPreviewSize(
      aspectRatio: geometry.aspectRatio,
      maximumSize: CGSize(width: 320, height: 280),
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

  private func preview() {
    quickLook?.present(
      .remote(
        source: file.source,
        name: file.name,
        mimeType: file.mimeType
      ),
      attachmentStore: attachmentImages
    )
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

// PDFBadge and VideoPlayBadge are shared with the iOS app via CodevisorUI.

/// A generic non-image attachment chip: document icon plus filename.
struct AttachmentFileChip: View {
  @Environment(\.theme) private var theme
  let name: String
  var onTap: (() -> Void)? = nil

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "doc")
        .foregroundStyle(.secondary)
      Text(name)
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(.primary)
    }
    .font(.callout)
    .padding(.horizontal, 10)
    .frame(height: 56)
    .frame(maxWidth: 200)
    .background(RoundedRectangle(cornerRadius: 8).fill(theme.bubbleBackground))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(.separator, lineWidth: 1)
    )
    .contentShape(RoundedRectangle(cornerRadius: 8))
    .onTapGesture { onTap?() }
    .help(name)
  }
}

// MARK: - Drop target

/// Makes one chat pane a drop target for files and images, with a full-area
/// "Drop to attach" overlay while a file hovers. Only file/image types are
/// registered, so text drags never light it up.
struct AttachmentDropModifier: ViewModifier {
  let controller: SessionController?
  @State private var isTargeted = false

  func body(content: Content) -> some View {
    content
      .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted) { providers in
        handleDrop(providers)
      }
      .overlay {
        if isTargeted && controller != nil {
          DropToAttachOverlay()
        }
      }
  }

  private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
    guard let controller else { return false }
    var handled = false
    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        handled = true
        let id = UUID()
        let name = provider.suggestedName ?? "Dropped file"
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
        let kind: Attachment.Kind =
          (type?.conforms(to: .image) ?? false) || mimeType.hasPrefix("image/")
          ? .image
          : .file
        guard
          controller.beginLoadingAttachment(
            id: id,
            name: name,
            mimeType: mimeType,
            kind: kind
          )
        else { continue }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
          let url =
            (item as? URL)
            ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
          Task { @MainActor in
            guard let url, url.isFileURL else {
              controller.discardLoadingAttachment(id: id)
              return
            }
            controller.resolveLoadingAttachment(id: id, fromFileURL: url)
          }
        }
      } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        handled = true
        let id = UUID()
        let suggestedName = provider.suggestedName
        let name =
          suggestedName.map { name in
            (name as NSString).pathExtension.isEmpty ? "\(name).png" : name
          } ?? "Dropped image.png"
        guard
          controller.beginLoadingAttachment(
            id: id,
            name: name,
            mimeType: "image/png",
            kind: .image
          )
        else { continue }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
          guard let data, let png = pngData(from: data) else {
            Task { @MainActor in
              controller.discardLoadingAttachment(id: id)
            }
            return
          }
          Task { @MainActor in
            controller.resolveLoadingAttachmentReportingFailure(
              id: id,
              name: name,
              mimeType: "image/png",
              kind: .image,
              data: png
            )
          }
        }
      }
    }
    return handled
  }
}

extension View {
  func attachmentDropTarget(_ controller: SessionController?) -> some View {
    modifier(AttachmentDropModifier(controller: controller))
  }
}

struct DropToAttachOverlay: View {
  @Environment(\.theme) private var theme

  var body: some View {
    ZStack {
      theme.windowBackground.opacity(0.92)
      RoundedRectangle(cornerRadius: 16)
        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        .foregroundStyle(theme.accent.opacity(0.8))
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

/// Normalizes arbitrary dropped/pasted image data (TIFF and friends) to PNG so
/// the stored file has a well-known type.
nonisolated func pngData(from imageData: Data) -> Data? {
  guard let bitmap = NSBitmapImageRep(data: imageData) else { return nil }
  return bitmap.representation(using: .png, properties: [:])
}
