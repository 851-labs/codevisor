import ACPKit
import CodevisorCore
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import os

/// Attachment-worthy content intercepted from the iOS composer's pasteboard.
enum PastedAttachment: Sendable {
    case fileURL(URL)
    /// The provider's original compressed representation whenever it fits the
    /// upload boundary; oversized images are downsampled to JPEG.
    case image(data: Data, suggestedName: String, mimeType: String)
}

/// A paste is represented in the composer before its asynchronous item
/// provider has supplied any bytes.
enum ComposerPasteEvent {
    case began(id: UUID, name: String, mimeType: String, kind: Attachment.Kind)
    case resolved(id: UUID, attachment: PastedAttachment)
    case failed(id: UUID, message: String, kind: Attachment.Kind)
}

/// Loads the representations advertised by paste item providers without
/// relying on `NSItemProvider` object coercion. In particular, synced Photos
/// pasteboards can advertise `public.file-url` while refusing to load an
/// `NSURL`; their raw URL data remains loadable.
enum ComposerPasteProviderLoader {
    private enum LoadResult {
        case success(PastedAttachment)
        case failure(String)
    }

    private static let log = Logger(
        subsystem: "com.851labs.codevisor",
        category: "composer-paste"
    )

    static func canLoadAttachment(from provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || preferredImageContentType(from: provider) != nil
    }

    static func logInvocation(route: String, providers: [NSItemProvider]) {
        let types =
            providers
            .flatMap(\.registeredTypeIdentifiers)
            .joined(separator: ",")
        log.notice(
            "PASTEDBG route=\(route, privacy: .public) count=\(providers.count) types=[\(types, privacy: .public)]"
        )
    }

    /// Emits `.began` synchronously so the attachment strip updates in the
    /// same run-loop turn as Paste, then resolves the provider asynchronously.
    @MainActor
    static func startLoading(
        from provider: NSItemProvider,
        onEvent: @escaping (ComposerPasteEvent) -> Void,
        onCompletion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        let id = UUID()
        let placeholder = placeholderMetadata(for: provider)
        onEvent(
            .began(
                id: id,
                name: placeholder.name,
                mimeType: placeholder.mimeType,
                kind: placeholder.kind
            )
        )
        Task {
            switch await loadAttachment(from: provider) {
            case let .success(attachment):
                onEvent(.resolved(id: id, attachment: attachment))
                onCompletion(true)
            case let .failure(message):
                onEvent(.failed(id: id, message: message, kind: placeholder.kind))
                onCompletion(false)
            }
        }
    }

    private static func loadAttachment(
        from provider: NSItemProvider
    ) async -> LoadResult {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
            let url = await fileURL(from: provider)
        {
            log.notice("PASTEDBG load.success kind=fileURL")
            return .success(.fileURL(url))
        }

        if let type = preferredImageContentType(from: provider),
            let data = await dataRepresentation(for: type, from: provider)
        {
            let name = normalizedSuggestedName(provider.suggestedName, contentType: type)
            guard
                let prepared = await prepareImage(
                    data: data,
                    suggestedName: name,
                    contentType: type
                )
            else {
                log.error("PASTEDBG load.failure reason=invalid-or-oversized-image")
                return .failure(
                    "Couldn't prepare the pasted image. Try copying it again or choose it from Photos."
                )
            }
            log.notice(
                "PASTEDBG load.success kind=image type=\(prepared.mimeType, privacy: .public) bytes=\(prepared.data.count)"
            )
            return .success(
                .image(
                    data: prepared.data,
                    suggestedName: prepared.name,
                    mimeType: prepared.mimeType
                )
            )
        }

        log.error("PASTEDBG load.failure reason=no-loadable-attachment-representation")
        return .failure(
            "Couldn't read the pasted image. Try copying it again or choose it from Photos."
        )
    }

    /// Universal Clipboard producers vary in how they vend public.file-url.
    /// Prefer the typed data, then ask for the NSURL object, the temporary
    /// file representation, and finally the explicitly advertised text URL.
    /// Every branch still has to produce a local file URL; the ICNS display
    /// representation is intentionally never considered content.
    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        if let data = await dataRepresentation(for: .fileURL, from: provider) {
            if let url = decodePasteboardFileURL(data) {
                log.debug("PASTEDBG fileURL.success route=data bytes=\(data.count)")
                return url
            }
            log.debug("PASTEDBG fileURL.data-undecodable bytes=\(data.count)")
        }

        if let url = await fileURLObject(from: provider) {
            log.debug("PASTEDBG fileURL.success route=object")
            return url
        }

        if let url = await fileURLFromTemporaryRepresentation(from: provider) {
            log.debug("PASTEDBG fileURL.success route=file-representation")
            return url
        }

        for type in [UTType.utf8PlainText, UTType.utf16ExternalPlainText]
        where provider.registeredTypeIdentifiers.contains(type.identifier) {
            if let data = await dataRepresentation(for: type, from: provider),
                let url = decodePasteboardFileURL(data)
            {
                log.debug(
                    "PASTEDBG fileURL.success route=text type=\(type.identifier, privacy: .public)"
                )
                return url
            }
        }
        return nil
    }

    private static func fileURLObject(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { object, error in
                if let error {
                    let error = error as NSError
                    log.debug(
                        "PASTEDBG representation.failure route=object domain=\(error.domain, privacy: .public) code=\(error.code)"
                    )
                }
                let url = (object as? NSURL).map { $0 as URL }
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    private static func fileURLFromTemporaryRepresentation(
        from provider: NSItemProvider
    ) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) {
                representationURL, error in
                if let error {
                    let error = error as NSError
                    log.debug(
                        "PASTEDBG representation.failure route=file-representation domain=\(error.domain, privacy: .public) code=\(error.code)"
                    )
                }
                let url =
                    representationURL
                    .flatMap { try? Data(contentsOf: $0) }
                    .flatMap(decodePasteboardFileURL)
                continuation.resume(returning: url)
            }
        }
    }

    private static func dataRepresentation(
        for type: UTType,
        from provider: NSItemProvider
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let error {
                    let error = error as NSError
                    log.debug(
                        "PASTEDBG representation.failure type=\(type.identifier, privacy: .public) domain=\(error.domain, privacy: .public) code=\(error.code)"
                    )
                }
                continuation.resume(returning: data)
            }
        }
    }

    private static func preferredImageContentType(from provider: NSItemProvider) -> UTType? {
        provider.registeredTypeIdentifiers.lazy
            .compactMap(UTType.init)
            .first {
                $0.conforms(to: .image)
                    && $0.identifier != UTType.image.identifier
                    // Finder/Universal Clipboard can advertise the source
                    // file's icon alongside public.file-url. That icon is UI
                    // metadata, never the pasted image itself.
                    && $0.identifier != "com.apple.icns"
            }
    }

    private static func placeholderMetadata(
        for provider: NSItemProvider
    ) -> (name: String, mimeType: String, kind: Attachment.Kind) {
        if let type = preferredImageContentType(from: provider) {
            return (
                normalizedSuggestedName(provider.suggestedName, contentType: type),
                type.preferredMIMEType ?? "application/octet-stream",
                .image
            )
        }
        let filename = cleanSuggestedName(provider.suggestedName) ?? "Pasted file"
        let type = UTType(filenameExtension: (filename as NSString).pathExtension)
        let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
        let kind: Attachment.Kind = type?.conforms(to: .image) == true ? .image : .file
        return (filename, mimeType, kind)
    }

    private static func cleanSuggestedName(_ suggestedName: String?) -> String? {
        guard let suggestedName,
            !suggestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let filename = (suggestedName as NSString).lastPathComponent
        return filename.isEmpty ? nil : filename
    }

    private static func normalizedSuggestedName(
        _ suggestedName: String?,
        contentType: UTType
    ) -> String {
        let fallback = "Pasted image \(timestamp()).\(contentType.preferredFilenameExtension ?? "img")"
        guard let filename = cleanSuggestedName(suggestedName) else { return fallback }
        let stem = (filename as NSString).deletingPathExtension
        guard !stem.isEmpty, let ext = contentType.preferredFilenameExtension else { return filename }
        return "\(stem).\(ext)"
    }

    static func prepareImage(
        data: Data,
        suggestedName: String,
        contentType: UTType
    ) async -> (data: Data, name: String, mimeType: String)? {
        let mimeType = contentType.preferredMIMEType ?? "application/octet-stream"
        let maxUploadBytes = SessionController.maxAttachmentUploadBytes
        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                CGImageSourceGetCount(source) > 0
            else { return nil }
            if data.count <= maxUploadBytes {
                return (data, suggestedName, mimeType)
            }

            // Only oversized images pay for decoding. Downsample before JPEG
            // encoding so peak memory and output size both stay bounded.
            let dimensions = [4096, 3072, 2048, 1536, 1024]
            let qualities: [CGFloat] = [0.9, 0.8, 0.7, 0.6]
            for dimension in dimensions {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: dimension,
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                else { continue }
                let uiImage = UIImage(cgImage: image)
                for quality in qualities {
                    guard let encoded = uiImage.jpegData(compressionQuality: quality) else { continue }
                    if encoded.count <= maxUploadBytes {
                        let stem = (suggestedName as NSString).deletingPathExtension
                        return (encoded, "\(stem.isEmpty ? "Pasted image" : stem).jpg", "image/jpeg")
                    }
                }
            }
            return nil
        }.value
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }
}
