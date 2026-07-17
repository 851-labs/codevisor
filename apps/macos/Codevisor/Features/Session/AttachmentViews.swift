import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import CodevisorCore

// MARK: - Image loading

/// Loads and caches attachment images from the session's server
/// (`GET /v1/files/:id`); the fetch goes through the controller's client so
/// bearer auth carries over for remote servers.
@MainActor
@Observable
final class AttachmentImageStore {
    private let fetch: (String) async throws -> Data
    private let cache = NSCache<NSString, NSImage>()
    private var failed: Set<String> = []

    init(fetch: @escaping (String) async throws -> Data) {
        self.fetch = fetch
    }

    func cachedImage(for fileId: String) -> NSImage? {
        cache.object(forKey: fileId as NSString)
    }

    func image(for attachment: Attachment) async -> NSImage? {
        if let cached = cachedImage(for: attachment.fileId) { return cached }
        guard !failed.contains(attachment.fileId) else { return nil }
        do {
            let data = try await fetch(attachment.fileId)
            let name = attachment.name
            let mimeType = attachment.mimeType
            let isVideo = attachment.isVideo
            guard let image = await Task.detached(priority: .userInitiated, operation: {
                await attachmentPreviewImage(
                    data: data,
                    name: name,
                    mimeType: mimeType,
                    isVideo: isVideo
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

// MARK: - Quick Look presentation

/// What Quick Look is showing: bytes already on hand (composer drafts) or a
/// stored file fetched by id (history).
enum QuickLookItem: Equatable {
    case local(data: Data, name: String, mimeType: String)
    case remote(fileId: String, name: String, mimeType: String)

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
    @Entry var attachmentImages: AttachmentImageStore? = nil
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

func attachmentIsVideo(name: String, mimeType: String) -> Bool {
    if mimeType.lowercased().hasPrefix("video/") { return true }
    let pathExtension = (name as NSString).pathExtension
    guard !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) else {
        return false
    }
    return type.conforms(to: .movie)
}

/// Decodes images/PDFs directly and asks AVFoundation for an early frame of a
/// video. AVFoundation needs a file URL, so video bytes are materialized only
/// for the duration of thumbnail generation.
nonisolated func attachmentPreviewImage(
    data: Data,
    name: String,
    mimeType: String,
    isVideo: Bool
) async -> NSImage? {
    guard isVideo else { return NSImage(data: data) }

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
        generator.maximumSize = NSSize(width: 240, height: 240)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        var frame = try? await generator.image(at: time)
        if frame == nil {
            frame = try? await generator.image(at: .zero)
        }
        guard let frame else { return nil }
        return NSImage(cgImage: frame.image, size: .zero)
    } catch {
        return nil
    }
}

/// The "PDF" tag shown over document previews so they read differently from
/// plain images.
struct PDFBadge: View {
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

/// A small rounded thumbnail for an image, PDF, or video attachment in the
/// transcript, or a file chip for other types. Every attachment opens with
/// Quick Look.
struct AttachmentThumbnailView: View {
    @Environment(\.theme) private var theme
    @Environment(\.quickLook) private var quickLook
    @Environment(\.attachmentImages) private var attachmentImages
    let attachment: Attachment

    @State private var image: NSImage?
    @State private var didLoad = false

    var body: some View {
        Group {
            if attachment.hasVisualPreview {
                imageThumb
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
            } else {
                AttachmentFileChip(name: attachment.name) {
                    preview()
                }
            }
        }
        .task(id: attachment.fileId) {
            guard attachment.hasVisualPreview, !didLoad else { return }
            didLoad = true
            image = await attachmentImages?.image(for: attachment)
        }
    }

    private var imageThumb: some View {
        // A tap gesture rather than a Button: buttons add their own
        // hover/press highlight over the artwork.
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.bubbleBackground)
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
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            preview()
        }
        .tooltip(attachment.name)
        .accessibilityLabel("Attachment \(attachment.name)")
        .accessibilityAddTraits(.isButton)
    }

    private func preview() {
        quickLook?.present(
            .remote(
                fileId: attachment.fileId,
                name: attachment.name,
                mimeType: attachment.mimeType
            ),
            attachmentStore: attachmentImages
        )
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
        .tooltip(name)
    }
}

// MARK: - Drop target

/// Makes the whole page a drop target for files and images, with a full-area
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
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url = (item as? URL)
                        ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in controller.attachFileURLs([url]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                let suggestedName = provider.suggestedName
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let png = pngData(from: data) else { return }
                    Task { @MainActor in
                        controller.attachImageData(png, suggestedName: suggestedName.map { "\($0).png" })
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
func pngData(from imageData: Data) -> Data? {
    guard let bitmap = NSBitmapImageRep(data: imageData) else { return nil }
    return bitmap.representation(using: .png, properties: [:])
}
