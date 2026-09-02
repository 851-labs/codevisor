import TranscriptKit
import CodevisorCore
import CodevisorUI
import QuickLook
import SwiftUI

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
struct AttachmentGeometryReadinessPreferenceKey: PreferenceKey {
  static var defaultValue = 0

  static func reduce(value: inout Int, nextValue: () -> Int) {
    value += nextValue()
  }
}

/// A rounded thumbnail for an image, PDF, or video attachment in the
/// transcript, or a file chip for other types. Tapping opens Quick Look.
struct AttachmentThumbnailView: View {
  @Environment(\.theme) private var theme
  @Environment(\.attachmentImages) private var attachmentImages
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let file: PreviewFile
  var inline: Bool

  @State private var image: UIImage?
  @State private var geometry = AttachmentPreviewGeometryState()
  @State private var quickLookURL: QuickLookURL?

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
    .sheet(item: $quickLookURL) { item in
      QuickLookPreview(url: item.url)
        .ignoresSafeArea()
        .presentationDragIndicator(.visible)
    }
  }

  private var imageThumb: some View {
    let size = thumbnailSize
    return ZStack {
      RoundedRectangle(cornerRadius: 8)
        .fill(theme.bubbleBackground)
      if let image {
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
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(.separator, lineWidth: 1)
    )
    .contentShape(RoundedRectangle(cornerRadius: 8))
    .onTapGesture { preview() }
    .accessibilityLabel("Attachment \(file.name)")
    .accessibilityAddTraits(.isButton)
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
    Button {
      preview()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "doc")
          .foregroundStyle(.secondary)
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
    .accessibilityLabel(file.name)
  }

  /// Quick Look needs a file URL: fetch the bytes and materialize them under
  /// the file's real filename so the preview titles correctly.
  private func preview() {
    guard let attachmentImages else { return }
    let file = self.file
    Task {
      guard let url = await materializeQuickLookURL(for: file, store: attachmentImages) else {
        return
      }
      quickLookURL = QuickLookURL(url: url)
    }
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

// MARK: - Quick Look

/// Fetches a transcript file and writes it under its real filename because
/// QLPreviewController presents file URLs rather than in-memory bytes.
@MainActor
/// The workspace file a Markdown link points at, or nil for web links and
/// fragments, which the platform opens instead.
func markdownLinkPreviewFile(_ url: URL) -> PreviewFile? {
  guard let path = markdownLocalFilePath(url.relativeString) else { return nil }
  return PreviewFile(serverPath: path)
}

func materializeQuickLookURL(
  for file: PreviewFile,
  store: AttachmentImageStore
) async -> URL? {
  guard let data = try? await store.data(for: file.source) else { return nil }
  return await materializeQuickLookURL(data: data, name: file.name)
}

/// Writes already-local attachment bytes under their display filename for
/// Quick Look. Composer attachments use this path while upload is still in
/// flight, so previewing never waits for the server round trip.
@MainActor
func materializeQuickLookURL(data: Data, name: String) async -> URL? {
  guard !data.isEmpty else { return nil }
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("Codevisor-QuickLook", isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  let lastPathComponent = (name as NSString).lastPathComponent
  let filename = lastPathComponent.isEmpty ? "Attachment" : lastPathComponent
  let url = directory.appendingPathComponent(filename)
  let written = await Task.detached(priority: .userInitiated) { () -> Bool in
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
      return true
    } catch {
      return false
    }
  }.value
  return written ? url : nil
}

struct QuickLookURL: Identifiable {
  let url: URL
  var id: String { url.path }
}

/// QLPreviewController wrapper: images, PDFs, and videos all preview (with
/// video playback) without per-type code. Wrapped in a navigation controller
/// so Quick Look's native Done and share chrome appears in the sheet.
struct QuickLookPreview: UIViewControllerRepresentable {
  let url: URL
  @Environment(\.dismiss) private var dismiss

  func makeUIViewController(context: Context) -> UINavigationController {
    let controller = QLPreviewController()
    controller.dataSource = context.coordinator
    let dismiss = self.dismiss
    controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
      systemItem: .close,
      primaryAction: UIAction { _ in dismiss() }
    )
    return UINavigationController(rootViewController: controller)
  }

  func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(url: url) }

  final class Coordinator: NSObject, QLPreviewControllerDataSource {
    private let url: URL

    init(url: URL) { self.url = url }

    nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    nonisolated func previewController(
      _ controller: QLPreviewController, previewItemAt index: Int
    ) -> QLPreviewItem {
      url as NSURL
    }
  }
}
