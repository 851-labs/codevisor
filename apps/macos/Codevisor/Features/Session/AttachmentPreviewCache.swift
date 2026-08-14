import AppKit
import AVFoundation
import CodevisorCore
import CryptoKit
import Observation
import UniformTypeIdentifiers

struct AttachmentPreviewImage {
    let image: NSImage
    let aspectRatio: CGFloat
    let version: String
}

private final class AttachmentPreviewBox {
    let value: AttachmentPreviewImage

    init(_ value: AttachmentPreviewImage) {
        self.value = value
    }
}

/// A per-session authenticated loader backed by one process-wide decoded
/// image cache and one bounded on-disk thumbnail cache. The namespace keeps
/// identical paths on different Codevisor machines isolated.
@MainActor
@Observable
final class AttachmentImageStore {
    typealias Fetch = (PreviewFile.Source) async throws -> Data
    typealias Version = (PreviewFile.Source) async throws -> String?

    private static let memory: NSCache<NSString, AttachmentPreviewBox> = {
        let cache = NSCache<NSString, AttachmentPreviewBox>()
        cache.countLimit = 96
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()

    private static var inFlight: [String: Task<AttachmentPreviewImage?, Never>] = [:]
    private static let disk = AttachmentPreviewDiskCache()

    let namespace: String
    private let fetch: Fetch
    private let version: Version
    private var versions: [String: String] = [:]

    init(namespace: String, fetch: @escaping Fetch, version: @escaping Version) {
        self.namespace = namespace
        self.fetch = fetch
        self.version = version
    }

    /// Returns the most recently persisted preview without revalidation. It
    /// provides stable geometry immediately on reopen; `image(for:)` then
    /// validates live paths and replaces stale pixels without resizing them.
    func cachedPreview(for file: PreviewFile) async -> AttachmentPreviewImage? {
        let key = baseKey(for: file.source)
        if let cached = Self.memory.object(forKey: key as NSString)?.value {
            return cached
        }
        guard let payload = await Self.disk.load(baseKey: key, expectedVersion: nil),
            let preview = await decodeDiskPayload(payload)
        else { return nil }
        storeInMemory(preview, key: key)
        return preview
    }

    /// Returns a validator-matched preview, fetching and decoding only on a
    /// true miss. Concurrent views requesting the same source share one task.
    func image(for file: PreviewFile) async -> AttachmentPreviewImage? {
        let key = baseKey(for: file.source)
        let resolvedVersion = await fileVersion(for: file.source)

        if let cached = Self.memory.object(forKey: key as NSString)?.value,
            cached.version == resolvedVersion
        {
            return cached
        }
        if let payload = await Self.disk.load(
            baseKey: key,
            expectedVersion: resolvedVersion
        ), let preview = await decodeDiskPayload(payload) {
            storeInMemory(preview, key: key)
            return preview
        }

        let requestKey = "\(key)\u{0}\(resolvedVersion)"
        if let task = Self.inFlight[requestKey] {
            return await task.value
        }

        let source = file.source
        let name = file.name
        let mimeType = file.mimeType
        let isVideo = file.isVideo
        let fetch = self.fetch
        let task = Task<AttachmentPreviewImage?, Never> {
            do {
                let data = try await fetch(source)
                guard
                    let image = await Task.detached(
                        priority: .userInitiated,
                        operation: {
                            await attachmentPreviewImage(
                                data: data,
                                name: name,
                                mimeType: mimeType,
                                isVideo: isVideo
                            )
                        }
                    ).value, let aspectRatio = previewAspectRatio(for: image.size)
                else { return nil }
                return AttachmentPreviewImage(
                    image: image,
                    aspectRatio: aspectRatio,
                    version: resolvedVersion
                )
            } catch {
                // Missing/deleted files stay as stable placeholders. A future
                // mount retries instead of pinning a transient failure forever.
                return nil
            }
        }
        Self.inFlight[requestKey] = task
        let loaded = await task.value
        Self.inFlight[requestKey] = nil
        guard let loaded else { return nil }

        storeInMemory(loaded, key: key)
        Task(priority: .utility) {
            if let encoded = await Task.detached(
                priority: .utility,
                operation: {
                    pngData(for: loaded.image)
                }
            ).value {
                await Self.disk.store(
                    baseKey: key,
                    version: loaded.version,
                    width: loaded.image.size.width,
                    height: loaded.image.size.height,
                    thumbnail: encoded
                )
            }
        }
        return loaded
    }

    func data(for source: PreviewFile.Source) async throws -> Data {
        try await fetch(source)
    }

    private func baseKey(for source: PreviewFile.Source) -> String {
        "\(namespace):\(source.cacheKey)"
    }

    private func fileVersion(for source: PreviewFile.Source) async -> String {
        if let cached = versions[source.cacheKey] { return cached }
        let resolved = (try? await version(source)) ?? "unversioned"
        versions[source.cacheKey] = resolved
        return resolved
    }

    private func decodeDiskPayload(
        _ payload: AttachmentPreviewDiskCache.Payload
    ) async -> AttachmentPreviewImage? {
        let image = await Task.detached(priority: .userInitiated) {
            NSImage(data: payload.thumbnail)
        }.value
        guard let image else { return nil }
        return AttachmentPreviewImage(
            image: image,
            aspectRatio: payload.width / payload.height,
            version: payload.version
        )
    }

    private func storeInMemory(_ preview: AttachmentPreviewImage, key: String) {
        let cost = preview.image.representations.reduce(0) { result, representation in
            result + max(1, representation.pixelsWide * representation.pixelsHigh * 4)
        }
        Self.memory.setObject(
            AttachmentPreviewBox(preview),
            forKey: key as NSString,
            cost: max(1, cost)
        )
    }
}

private actor AttachmentPreviewDiskCache {
    struct Payload: Sendable {
        let version: String
        let width: CGFloat
        let height: CGFloat
        let thumbnail: Data
    }

    private struct Metadata: Codable {
        let baseKey: String
        let version: String
        let width: Double
        let height: Double
    }

    private struct Entry {
        let thumbnailURL: URL
        let metadataURL: URL
        let size: Int
        let modifiedAt: Date
    }

    private let maximumBytes = 128 * 1_024 * 1_024
    private let maximumEntries = 256
    private let directory: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory =
            caches
            .appendingPathComponent("Codevisor", isDirectory: true)
            .appendingPathComponent("AttachmentThumbnails-v1", isDirectory: true)
    }

    func load(baseKey: String, expectedVersion: String?) -> Payload? {
        let urls = entryURLs(for: baseKey)
        guard let metadataData = try? Data(contentsOf: urls.metadata),
            let metadata = try? JSONDecoder().decode(Metadata.self, from: metadataData),
            metadata.baseKey == baseKey,
            expectedVersion == nil || metadata.version == expectedVersion,
            metadata.width.isFinite,
            metadata.height.isFinite,
            metadata.width > 0,
            metadata.height > 0,
            let thumbnail = try? Data(contentsOf: urls.thumbnail)
        else { return nil }

        let now = Date()
        try? FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: urls.thumbnail.path
        )
        try? FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: urls.metadata.path
        )
        return Payload(
            version: metadata.version,
            width: metadata.width,
            height: metadata.height,
            thumbnail: thumbnail
        )
    }

    func store(
        baseKey: String,
        version: String,
        width: CGFloat,
        height: CGFloat,
        thumbnail: Data
    ) {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let urls = entryURLs(for: baseKey)
            let metadata = Metadata(
                baseKey: baseKey,
                version: version,
                width: width,
                height: height
            )
            try thumbnail.write(to: urls.thumbnail, options: .atomic)
            try JSONEncoder().encode(metadata).write(to: urls.metadata, options: .atomic)
            trimIfNeeded()
        } catch {
            // The OS may clear Caches or reject a write under storage pressure;
            // previews remain functional through the bounded memory tier.
        }
    }

    private func entryURLs(for baseKey: String) -> (thumbnail: URL, metadata: URL) {
        let digest = SHA256.hash(data: Data(baseKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return (
            directory.appendingPathComponent("\(digest).thumb"),
            directory.appendingPathComponent("\(digest).json")
        )
    }

    private func trimIfNeeded() {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard
            let files = try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        else { return }

        var entries: [Entry] = files.compactMap { thumbnailURL in
            guard thumbnailURL.pathExtension == "thumb",
                let values = try? thumbnailURL.resourceValues(forKeys: keys)
            else { return nil }
            return Entry(
                thumbnailURL: thumbnailURL,
                metadataURL: thumbnailURL.deletingPathExtension().appendingPathExtension("json"),
                size: values.fileSize ?? 0,
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }
        var totalBytes = entries.reduce(0) { $0 + $1.size }
        guard entries.count > maximumEntries || totalBytes > maximumBytes else { return }
        entries.sort { $0.modifiedAt < $1.modifiedAt }
        while entries.count > maximumEntries || totalBytes > maximumBytes {
            let evicted = entries.removeFirst()
            totalBytes -= evicted.size
            try? manager.removeItem(at: evicted.thumbnailURL)
            try? manager.removeItem(at: evicted.metadataURL)
        }
    }
}

private nonisolated func previewAspectRatio(for size: CGSize) -> CGFloat? {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
        return nil
    }
    return size.width / size.height
}

private nonisolated func pngData(for image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
        let representation = NSBitmapImageRep(data: tiff)
    else { return nil }
    return representation.representation(using: .png, properties: [:])
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

        let pathExtension =
            (name as NSString).pathExtension.isEmpty
            ? (UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "mp4")
            : (name as NSString).pathExtension
        let file = directory.appendingPathComponent("preview.\(pathExtension)")
        try data.write(to: file, options: .atomic)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = NSSize(width: 480, height: 480)
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
