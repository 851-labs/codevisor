import AVFoundation
import CodevisorCore
import CodevisorUI
import PDFKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Image loading

/// Loads and caches attachment images from the session's server
/// (`GET /v1/files/:id`); the fetch goes through the controller's client so
/// bearer auth carries over. The iOS twin of the macOS AttachmentImageStore.
@MainActor
@Observable
final class AttachmentImageStore {
    private let fetch: (String) async throws -> Data
    private let cache = NSCache<NSString, UIImage>()
    private var failed: Set<String> = []

    init(fetch: @escaping (String) async throws -> Data) {
        self.fetch = fetch
    }

    func image(for attachment: Attachment) async -> UIImage? {
        if let cached = cache.object(forKey: attachment.fileId as NSString) { return cached }
        guard !failed.contains(attachment.fileId) else { return nil }
        do {
            let data = try await fetch(attachment.fileId)
            let name = attachment.name
            let mimeType = attachment.mimeType
            let isVideo = attachment.isVideo
            let isPDF = attachment.isPDF
            guard let image = await Task.detached(priority: .userInitiated, operation: {
                await attachmentPreviewImage(
                    data: data, name: name, mimeType: mimeType, isVideo: isVideo, isPDF: isPDF
                )
            }).value else {
                failed.insert(attachment.fileId)
                return nil
            }
            cache.setObject(image, forKey: attachment.fileId as NSString)
            return image
        } catch {
            // Missing files (deleted DB, cross-server session) render as a
            // placeholder rather than erroring the transcript.
            failed.insert(attachment.fileId)
            return nil
        }
    }

    func data(for fileId: String) async throws -> Data {
        try await fetch(fileId)
    }
}

extension EnvironmentValues {
    @Entry var attachmentImages: AttachmentImageStore? = nil
}

extension Attachment {
    /// PDFs render like images rather than as generic file chips.
    var isPDF: Bool {
        mimeType == "application/pdf" || name.lowercased().hasSuffix(".pdf")
    }

    var isVideo: Bool { attachmentIsVideo(name: name, mimeType: mimeType) }

    var hasVisualPreview: Bool { kind == .image || isPDF || isVideo }
}

/// Decodes images directly, renders the first page of a PDF, and asks
/// AVFoundation for an early frame of a video (which needs a file URL, so
/// video bytes are materialized only for the duration of the thumbnail).
private nonisolated func attachmentPreviewImage(
    data: Data,
    name: String,
    mimeType: String,
    isVideo: Bool,
    isPDF: Bool
) async -> UIImage? {
    if isPDF {
        guard let page = PDFDocument(data: data)?.page(at: 0) else { return nil }
        return page.thumbnail(of: CGSize(width: 240, height: 240), for: .cropBox)
    }
    guard isVideo else {
        return UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 480, height: 480))
            ?? UIImage(data: data)
    }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Codevisor-Video-Thumbnails", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pathExtension = (name as NSString).pathExtension.isEmpty
            ? (UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "mp4")
            : (name as NSString).pathExtension
        let file = directory.appendingPathComponent("preview.\(pathExtension)")
        try data.write(to: file, options: .atomic)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        var frame = try? await generator.image(at: time)
        if frame == nil {
            frame = try? await generator.image(at: .zero)
        }
        guard let frame else { return nil }
        return UIImage(cgImage: frame.image)
    } catch {
        return nil
    }
}

// MARK: - Transcript thumbnails

/// A rounded thumbnail for an image, PDF, or video attachment in the
/// transcript, or a file chip for other types. Tapping opens Quick Look.
struct AttachmentThumbnailView: View {
    @Environment(\.theme) private var theme
    @Environment(\.attachmentImages) private var attachmentImages
    let attachment: Attachment
    var inline = false

    @State private var image: UIImage?
    @State private var quickLookURL: QuickLookURL?

    var body: some View {
        Group {
            if attachment.hasVisualPreview {
                imageThumb
                    .overlay(alignment: .bottomLeading) {
                        if attachment.isPDF { PDFTagBadge() }
                    }
                    .overlay {
                        if attachment.isVideo { VideoPlayBadge() }
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
        .task(id: AttachmentThumbnailLoadID(attachment: attachment, store: attachmentImages)) {
            guard attachment.hasVisualPreview, let attachmentImages else { return }
            let loaded = await attachmentImages.image(for: attachment)
            guard !Task.isCancelled else { return }
            image = loaded
        }
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
                Image(systemName: attachment.isVideo ? "video" : "photo")
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
        .accessibilityLabel("Attachment \(attachment.name)")
        .accessibilityAddTraits(.isButton)
    }

    private var thumbnailSize: CGSize {
        guard inline else { return CGSize(width: 56, height: 56) }
        return boundedAttachmentPreviewSize(
            aspectRatio: image.flatMap { previewAspectRatio(for: $0.size) },
            maximumSize: CGSize(width: 280, height: 280),
            fallbackAspectRatio: attachment.isPDF ? 8.5 / 11.0 : 16.0 / 9.0
        )
    }

    private func previewAspectRatio(for size: CGSize) -> CGFloat? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return nil
        }
        return size.width / size.height
    }

    private var fileChip: some View {
        Button {
            preview()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                Text(attachment.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: 56)
            .frame(maxWidth: 200)
            .background(theme.bubbleBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(attachment.name)
    }

    /// Quick Look needs a file URL: fetch the bytes and materialize them under
    /// the attachment's real filename so the preview titles correctly.
    private func preview() {
        guard let attachmentImages else { return }
        let attachment = self.attachment
        Task {
            guard let data = try? await attachmentImages.data(for: attachment.fileId) else { return }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Codevisor-QuickLook", isDirectory: true)
                .appendingPathComponent(attachment.fileId, isDirectory: true)
            let url = directory.appendingPathComponent(attachment.name)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                quickLookURL = QuickLookURL(url: url)
            } catch {}
        }
    }
}

private struct AttachmentThumbnailLoadID: Hashable {
    let fileId: String
    let storeID: ObjectIdentifier?

    init(attachment: Attachment, store: AttachmentImageStore?) {
        fileId = attachment.fileId
        storeID = store.map { ObjectIdentifier($0) }
    }
}

struct PDFTagBadge: View {
    var body: some View {
        Text("PDF")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.55)))
            .padding(4)
            .allowsHitTesting(false)
    }
}

struct VideoPlayBadge: View {
    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Circle().fill(.black.opacity(0.6)))
            .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
            .allowsHitTesting(false)
    }
}

// MARK: - Quick Look

private struct QuickLookURL: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// QLPreviewController wrapper: images, PDFs, and videos all preview (with
/// video playback) without per-type code. Wrapped in a navigation controller
/// so Quick Look's native Done and share chrome appears in the sheet.
private struct QuickLookPreview: UIViewControllerRepresentable {
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
