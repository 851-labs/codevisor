import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HerdManCore

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

    func image(for fileId: String) async -> NSImage? {
        if let cached = cachedImage(for: fileId) { return cached }
        guard !failed.contains(fileId) else { return nil }
        do {
            let data = try await fetch(fileId)
            guard let image = NSImage(data: data) else {
                failed.insert(fileId)
                return nil
            }
            cache.setObject(image, forKey: fileId as NSString)
            return image
        } catch {
            // Missing files (deleted DB, cross-server session) render as a
            // placeholder rather than erroring the transcript.
            failed.insert(fileId)
            return nil
        }
    }

    func data(for fileId: String) async throws -> Data {
        try await fetch(fileId)
    }
}

// MARK: - Lightbox presentation

/// What the lightbox is showing: bytes already on hand (composer drafts) or a
/// stored file fetched by id (history).
enum LightboxItem: Equatable {
    case local(data: Data, name: String)
    case remote(fileId: String, name: String)

    var name: String {
        switch self {
        case let .local(_, name): return name
        case let .remote(_, name): return name
        }
    }
}

/// Window-level lightbox state; presented as an overlay at the app root so it
/// covers the whole window, not just the session column.
@MainActor
@Observable
final class LightboxController {
    var item: LightboxItem?
    /// Resolves remote items; stamped by the screen that presented the item.
    var imageStore: AttachmentImageStore?

    func present(_ item: LightboxItem, imageStore: AttachmentImageStore?) {
        self.imageStore = imageStore
        self.item = item
    }

    func dismiss() {
        item = nil
    }
}

extension EnvironmentValues {
    @Entry var lightbox: LightboxController? = nil
    @Entry var attachmentImages: AttachmentImageStore? = nil
}

// MARK: - Thumbnails

extension Attachment {
    /// PDFs render like images (NSImage/PDFKit handle the data) rather than
    /// as generic file chips.
    var isPDF: Bool {
        mimeType == "application/pdf" || name.lowercased().hasSuffix(".pdf")
    }

    var hasVisualPreview: Bool { kind == .image || isPDF }
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

/// A small rounded thumbnail for an image or PDF attachment in the
/// transcript, or a file chip for other types. Clicking a preview opens the
/// lightbox; clicking a file offers a save panel.
struct AttachmentThumbnailView: View {
    @Environment(\.theme) private var theme
    @Environment(\.lightbox) private var lightbox
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
            } else {
                AttachmentFileChip(name: attachment.name) {
                    saveFile()
                }
            }
        }
        .task(id: attachment.fileId) {
            guard attachment.hasVisualPreview, !didLoad else { return }
            didLoad = true
            image = await attachmentImages?.image(for: attachment.fileId)
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
                Image(systemName: "photo")
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
            lightbox?.present(
                .remote(fileId: attachment.fileId, name: attachment.name),
                imageStore: attachmentImages
            )
        }
        .help(attachment.name)
        .accessibilityLabel("Attached image \(attachment.name)")
        .accessibilityAddTraits(.isButton)
    }

    private func saveFile() {
        guard let attachmentImages else { return }
        let attachment = attachment
        Task { @MainActor in
            guard let data = try? await attachmentImages.data(for: attachment.fileId) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = attachment.name
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
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
        .help(name)
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
