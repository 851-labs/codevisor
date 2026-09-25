import AVFoundation
import CodevisorCore
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import PDFKit
  import UIKit
#endif

// `@unchecked` for the AppKit image: both apps already hop these decoded
// previews between the main actor and detached decode/encode tasks (UIImage
// is Sendable; immutable NSImage use here matches that shipped behavior).
public struct AttachmentPreviewImage: @unchecked Sendable {
  public let image: OSImage
  public let aspectRatio: CGFloat
  public let version: String
}

private final class AttachmentPreviewBox {
  let value: AttachmentPreviewImage

  init(_ value: AttachmentPreviewImage) {
    self.value = value
  }
}

extension PreviewFile {
  fileprivate var isPDF: Bool {
    mimeType == "application/pdf" || name.lowercased().hasSuffix(".pdf")
  }

  fileprivate var isVideo: Bool { attachmentIsVideo(name: name, mimeType: mimeType) }
}

/// A per-session authenticated loader backed by one process-wide decoded
/// image cache and one bounded on-disk thumbnail cache. The namespace keeps
/// identical paths on different Codevisor machines isolated.
@MainActor
@Observable
public final class AttachmentImageStore {
  public typealias Fetch = (PreviewFile.Source) async throws -> Data
  public typealias Version = (PreviewFile.Source) async throws -> String?

  private static let memory: NSCache<NSString, AttachmentPreviewBox> = {
    let cache = NSCache<NSString, AttachmentPreviewBox>()
    cache.countLimit = 96
    cache.totalCostLimit = 64 * 1_024 * 1_024
    return cache
  }()

  private static var inFlight: [String: Task<AttachmentPreviewImage?, Never>] = [:]
  private static let disk = AttachmentPreviewDiskCache()

  private static var activePreviews = 0
  private static var previewWaiters: [CheckedContinuation<Bool, Never>] = []

  private static func acquirePreviewSlot() async -> Bool {
    if activePreviews < 4 { activePreviews += 1; return true }
    guard previewWaiters.count < 64 else { return false }
    return await withCheckedContinuation { previewWaiters.append($0) }
  }

  private static func releasePreviewSlot() {
    if previewWaiters.isEmpty { activePreviews -= 1 } else { previewWaiters.removeFirst().resume(returning: true) }
  }

  public let namespace: String
  private let fetch: Fetch
  private let fetchPreview: Fetch
  private let version: Version
  private var versions: [String: String] = [:]

  public init(namespace: String, fetch: @escaping Fetch, fetchPreview: @escaping Fetch, version: @escaping Version) {
    self.namespace = namespace
    self.fetch = fetch
    self.fetchPreview = fetchPreview
    self.version = version
  }

  /// The decoded preview already in memory, synchronously. A view that
  /// mounts over pixels another view already loaded (the copy of a row
  /// that flies out of the composer) draws them in its first frame
  /// instead of flashing a placeholder until its own load task runs.
  public func memoryPreview(for file: PreviewFile) -> AttachmentPreviewImage? {
    Self.memory.object(forKey: baseKey(for: file.source) as NSString)?.value
  }

  /// Returns the most recently persisted preview without revalidation. It
  /// provides stable geometry immediately on reopen; `image(for:)` then
  /// validates live paths and replaces stale pixels without resizing them.
  public func cachedPreview(for file: PreviewFile) async -> AttachmentPreviewImage? {
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
  public func image(for file: PreviewFile) async -> AttachmentPreviewImage? {
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
    let fetchPreview = self.fetchPreview
    let task = Task<AttachmentPreviewImage?, Never> {
      guard await Self.acquirePreviewSlot() else { return nil }
      defer { Self.releasePreviewSlot() }
      do {
        let data = try await fetchPreview(source)
        guard data.count <= 1024 * 1024 else { return nil }
        return await Task.detached(priority: .userInitiated) {
          guard
            let source = CGImageSourceCreateWithData(
              data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let pixels = CGImageSourceCreateThumbnailAtIndex(
              source, 0,
              [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
              ] as CFDictionary)
          else { return nil as AttachmentPreviewImage? }
          #if canImport(AppKit)
            let image = NSImage(cgImage: pixels, size: NSSize(width: pixels.width, height: pixels.height))
          #else
            let image = UIImage(cgImage: pixels)
          #endif
          return AttachmentPreviewImage(
            image: image, aspectRatio: CGFloat(pixels.width) / CGFloat(pixels.height), version: resolvedVersion)
        }.value
      } catch { return nil }
    }
    Self.inFlight[requestKey] = task
    let loaded = await task.value
    Self.inFlight[requestKey] = nil
    guard let loaded else { return nil }

    storeInMemory(loaded, key: key)
    Task(priority: .utility) {
      if let encoded = await Task.detached(
        priority: .utility,
        operation: { () -> Data? in
          #if canImport(AppKit)
            return pngData(for: loaded.image)
          #elseif canImport(UIKit)
            return loaded.image.pngData()
          #endif
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

  public func data(for source: PreviewFile.Source) async throws -> Data {
    try await fetch(source)
  }

  private func baseKey(for source: PreviewFile.Source) -> String {
    "preview-480-v2:\(namespace):\(source.cacheKey)"
  }

  private func fileVersion(for source: PreviewFile.Source) async -> String {
    if let cached = versions[source.cacheKey] { return cached }
    let resolved = (try? await version(source)) ?? "unversioned"
    if versions.count >= 256 { versions.removeAll(keepingCapacity: true) }
    versions[source.cacheKey] = resolved
    return resolved
  }

  private func decodeDiskPayload(
    _ payload: AttachmentPreviewDiskCache.Payload
  ) async -> AttachmentPreviewImage? {
    let image = await Task.detached(priority: .userInitiated) {
      OSImage(data: payload.thumbnail)
    }.value
    guard let image else { return nil }
    return AttachmentPreviewImage(
      image: image,
      aspectRatio: payload.width / payload.height,
      version: payload.version
    )
  }

  private func storeInMemory(_ preview: AttachmentPreviewImage, key: String) {
    #if canImport(AppKit)
      let cost = preview.image.representations.reduce(0) { result, representation in
        result + max(1, representation.pixelsWide * representation.pixelsHigh * 4)
      }
    #elseif canImport(UIKit)
      let cost =
        preview.image.cgImage.map { $0.bytesPerRow * $0.height }
        ?? Int(preview.image.size.width * preview.image.size.height * 4)
    #endif
    Self.memory.setObject(
      AttachmentPreviewBox(preview),
      forKey: key as NSString,
      cost: max(1, cost)
    )
  }
}

extension EnvironmentValues {
  @Entry public var attachmentImages: AttachmentImageStore? = nil
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
    directory =
      CodevisorAppVariant.cacheURL()
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

#if canImport(AppKit)
  private nonisolated func pngData(for image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
      let representation = NSBitmapImageRep(data: tiff)
    else { return nil }
    return representation.representation(using: .png, properties: [:])
  }

#endif

/// A composer thumbnail rendered straight from the staged file: ImageIO
/// downsamples an image without decoding it at full size, PDFs render their
/// first page, and AVFoundation grabs an early frame of a video.
public nonisolated func attachmentPreviewImage(
  fileURL: URL,
  isVideo: Bool,
  isPDF: Bool
) async -> OSImage? {
  let maxPixelSize: CGFloat = 480
  if isVideo {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
    let time = CMTime(seconds: 0.1, preferredTimescale: 600)
    var frame = try? await generator.image(at: time)
    if frame == nil {
      frame = try? await generator.image(at: .zero)
    }
    guard let frame else { return nil }
    return osImage(frame.image)
  }
  if isPDF {
    #if canImport(AppKit)
      return NSImage(contentsOf: fileURL)
    #else
      guard let page = PDFDocument(url: fileURL)?.page(at: 0) else { return nil }
      return page.thumbnail(of: CGSize(width: maxPixelSize, height: maxPixelSize), for: .cropBox)
    #endif
  }
  guard
    let source = CGImageSourceCreateWithURL(
      fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
    let image = CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      ] as CFDictionary)
  else { return nil }
  return osImage(image)
}

private nonisolated func osImage(_ image: CGImage) -> OSImage {
  #if canImport(AppKit)
    NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  #else
    UIImage(cgImage: image)
  #endif
}
