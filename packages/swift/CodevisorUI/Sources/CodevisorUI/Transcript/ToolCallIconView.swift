import CodevisorCore
import CryptoKit
import ImageIO
import SwiftUI

/// The icon column every tool row shares, so a group's rows line up their
/// icons in one column and their labels after it.
enum ToolIconMetrics {
  static var font: Font {
    // One notch under the row label on both platforms: macOS pairs a 12pt
    // callout icon with 13pt body text; iOS rows label at callout 16, so the
    // icon sits at subheadline 15.
    #if os(iOS)
      .subheadline
    #else
      .callout
    #endif
  }

  static var columnWidth: CGFloat {
    #if os(iOS)
      // The terminal symbol is slightly wider than the old 16pt column.
      // Keep its ink inside the clipped transcript-row host.
      18
    #else
      16
    #endif
  }

  static var spacing: CGFloat {
    #if os(iOS)
      // Preserve the existing 24pt icon-column-plus-gap label inset.
      6
    #else
      8
    #endif
  }

  /// Artwork reads at the symbol's cap height, not the column's width.
  static var artworkSide: CGFloat {
    #if os(iOS)
      15
    #else
      14
    #endif
  }

  static var labelInset: CGFloat { columnWidth + spacing }
}

/// A tool call's icon: its SF Symbol, replaced by server-resolved artwork
/// (a site's favicon, an MCP server's icon) once that is available. Artwork
/// comes from a memory cache in the first frame and from disk on reopen,
/// so a returning chat draws its icons without waiting on the network.
public struct ToolCallIconView: View {
  let icon: ToolCallIcon

  @Environment(\.transcriptController) private var controller
  @Environment(\.colorScheme) private var colorScheme
  @State private var loaded: LoadedArtwork?

  public init(icon: ToolCallIcon) {
    self.icon = icon
  }

  private var request: ToolIconImages.Request? {
    guard let artwork = icon.artwork, let controller else { return nil }
    return ToolIconImages.Request(
      namespace: controller.toolIconCacheNamespace,
      artwork: artwork,
      dark: colorScheme == .dark
    )
  }

  public var body: some View {
    let request = request
    let artwork = request.flatMap { loaded?.request == $0 ? loaded?.artwork : ToolIconImages.memoryArtwork(for: $0) }
    Group {
      if let artwork {
        // Dark marks (GitHub's octocat) vanish on a dark transcript; give
        // them the light plate browsers give such tab icons.
        let plated = artwork.isDark && colorScheme == .dark
        artworkImage(artwork.image)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .padding(plated ? 1.5 : 0)
          .frame(width: ToolIconMetrics.artworkSide, height: ToolIconMetrics.artworkSide)
          .background {
            if plated { RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(.white.opacity(0.9)) }
          }
          .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
      } else {
        Image(systemName: icon.symbol)
          .font(ToolIconMetrics.font)
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: ToolIconMetrics.columnWidth)
    .accessibilityHidden(true)
    .task(id: request) {
      guard let request, let controller else { return }
      if loaded?.request == request { return }
      let artwork = await ToolIconImages.artwork(for: request) { [weak controller] request in
        guard let controller else { throw SessionControllerError.serverUnavailable }
        return try await controller.toolIconData(request)
      }
      guard !Task.isCancelled, let artwork else { return }
      loaded = LoadedArtwork(request: request, artwork: artwork)
    }
  }

  private func artworkImage(_ image: OSImage) -> Image {
    #if os(macOS)
      Image(nsImage: image)
    #else
      Image(uiImage: image)
    #endif
  }
}

private struct LoadedArtwork {
  let request: ToolIconImages.Request
  let artwork: ToolIconArtwork
}

/// Decoded tool artwork, and whether its ink is dark enough to need a light
/// plate in dark mode.
struct ToolIconArtwork {
  let image: OSImage
  let isDark: Bool
}

/// Decoded tool artwork shared by every transcript row: a process-wide
/// memory tier, a bounded on-disk tier that survives relaunch, and one
/// in-flight fetch per icon. "No artwork" is remembered too, so a site
/// without a favicon isn't asked again on every row mount.
@MainActor
enum ToolIconImages {
  struct Request: Hashable, Sendable {
    let namespace: String
    let artwork: ToolCallIcon.Artwork
    let dark: Bool

    var key: String {
      switch artwork {
      case let .site(origin):
        return "\(namespace)|site|\(origin)|\(dark)"
      case let .mcpServer(id, host):
        return "\(namespace)|mcp|\(id)|\(host ?? "")|\(dark)"
      }
    }

    var serverRequest: ServerToolIconRequest {
      switch artwork {
      case let .site(origin): .site(origin: origin, dark: dark)
      case let .mcpServer(id, host): .mcpServer(id: id, host: host, dark: dark)
      }
    }
  }

  typealias Fetch = @Sendable (ServerToolIconRequest) async throws -> Data

  private final class Box {
    let artwork: ToolIconArtwork?
    let expiresAt: Date

    init(artwork: ToolIconArtwork?, expiresAt: Date) {
      self.artwork = artwork
      self.expiresAt = expiresAt
    }
  }

  private static let memory: NSCache<NSString, Box> = {
    let cache = NSCache<NSString, Box>()
    cache.countLimit = 512
    return cache
  }()

  private static var inFlight: [String: Task<ToolIconArtwork?, Never>] = [:]
  private static let disk = ToolIconDiskCache()

  /// Artwork already decoded this run, for a row's first frame.
  static func memoryArtwork(for request: Request) -> ToolIconArtwork? {
    memory.object(forKey: request.key as NSString)?.artwork
  }

  static func artwork(for request: Request, fetch: @escaping Fetch) async -> ToolIconArtwork? {
    let key = request.key
    if let box = memory.object(forKey: key as NSString), box.artwork != nil || box.expiresAt > .now {
      return box.artwork
    }
    if let running = inFlight[key] { return await running.value }
    let task = Task<ToolIconArtwork?, Never> {
      defer { inFlight[key] = nil }
      let stored = await disk.load(key: key)
      if case let .image(data, isFresh) = stored, let artwork = await decode(data) {
        memory.setObject(Box(artwork: artwork, expiresAt: .distantFuture), forKey: key as NSString)
        // Stale artwork still draws now; the refresh replaces it quietly.
        if !isFresh { Task { await refresh(request, fetch: fetch, fallback: artwork) } }
        return artwork
      }
      if case .missing = stored {
        memory.setObject(Box(artwork: nil, expiresAt: .now.addingTimeInterval(60)), forKey: key as NSString)
        return nil
      }
      return await refresh(request, fetch: fetch, fallback: nil)
    }
    inFlight[key] = task
    return await task.value
  }

  @discardableResult
  private static func refresh(
    _ request: Request, fetch: Fetch, fallback: ToolIconArtwork?
  ) async -> ToolIconArtwork? {
    let key = request.key
    do {
      let data = try await fetch(request.serverRequest)
      guard let artwork = await decode(data) else {
        await disk.storeMissing(key: key)
        memory.setObject(Box(artwork: fallback, expiresAt: .now.addingTimeInterval(60)), forKey: key as NSString)
        return fallback
      }
      await disk.store(key: key, data: data)
      memory.setObject(Box(artwork: artwork, expiresAt: .distantFuture), forKey: key as NSString)
      return artwork
    } catch let CodevisorServerClientError.httpStatus(status, _) where status == 404 {
      // The server looked and found nothing; it will look again later.
      await disk.storeMissing(key: key)
      memory.setObject(Box(artwork: fallback, expiresAt: .now.addingTimeInterval(60)), forKey: key as NSString)
      return fallback
    } catch {
      // Offline or unreachable: keep any artwork, retry on a later mount.
      memory.setObject(Box(artwork: fallback, expiresAt: .now.addingTimeInterval(30)), forKey: key as NSString)
      return fallback
    }
  }

  /// The sharpest frame (ICO files hold several), thumbnailed to row size.
  /// Anything ImageIO can't read is no artwork at all.
  private static func decode(_ data: Data) async -> ToolIconArtwork? {
    let decoded = await Task.detached(priority: .utility) { () -> (CGImage, Bool)? in
      guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
      let count = CGImageSourceGetCount(source)
      guard count > 0 else { return nil }
      var best = 0
      var bestWidth = 0
      for index in 0..<count {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        if width > bestWidth {
          best = index
          bestWidth = width
        }
      }
      guard
        let image = CGImageSourceCreateThumbnailAtIndex(
          source,
          best,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
          ] as CFDictionary
        )
      else { return nil }
      return (image, isDarkInk(image))
    }.value
    guard let (cgImage, isDark) = decoded else { return nil }
    #if os(macOS)
      let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    #else
      let image = UIImage(cgImage: cgImage)
    #endif
    return ToolIconArtwork(image: image, isDark: isDark)
  }

  /// Whether the visible (non-transparent) pixels are mostly dark ink on
  /// transparency, judged on a 16×16 sample. Opaque artwork brings its own
  /// background, so only see-through marks qualify.
  nonisolated static func isDarkInk(_ image: CGImage) -> Bool {
    let side = 16
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    guard drawn else { return false }
    var visible = 0
    var transparent = 0
    var luminance = 0.0
    for index in stride(from: 0, to: pixels.count, by: 4) {
      let alpha = Double(pixels[index + 3]) / 255
      guard alpha > 0.5 else {
        transparent += 1
        continue
      }
      visible += 1
      // Premultiplied: divide alpha back out before weighing the channels.
      let red = Double(pixels[index]) / 255 / alpha
      let green = Double(pixels[index + 1]) / 255 / alpha
      let blue = Double(pixels[index + 2]) / 255 / alpha
      luminance += 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
    guard visible > 0, transparent > side * side / 8 else { return false }
    return luminance / Double(visible) < 0.3
  }
}

/// Raw artwork bytes by request key under Caches. Artwork older than three
/// days is revalidated in the background; a remembered miss lasts an hour.
private actor ToolIconDiskCache {
  enum Stored {
    case image(Data, isFresh: Bool)
    case missing
  }

  private let directory = CodevisorAppVariant.cacheURL()
    .appendingPathComponent("ToolIcons-v1", isDirectory: true)
  private let freshFor: TimeInterval = 3 * 24 * 60 * 60
  private let missFor: TimeInterval = 60 * 60
  private let maximumEntries = 1_024
  private var writes = 0

  func load(key: String) -> Stored? {
    let url = fileURL(for: key)
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let modified = attributes[.modificationDate] as? Date
    else { return nil }
    let age = Date.now.timeIntervalSince(modified)
    guard let data = try? Data(contentsOf: url) else { return nil }
    if data.isEmpty { return age < missFor ? .missing : nil }
    return .image(data, isFresh: age < freshFor)
  }

  func store(key: String, data: Data) {
    write(data, to: fileURL(for: key))
  }

  func storeMissing(key: String) {
    write(Data(), to: fileURL(for: key))
  }

  private func write(_ data: Data, to url: URL) {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
    } catch {
      // Caches may be cleared or full; the memory tier still serves this run.
    }
    writes += 1
    if writes % 64 == 0 { trim() }
  }

  /// Oldest-first eviction once the directory outgrows its bound.
  private func trim() {
    let manager = FileManager.default
    guard
      let urls = try? manager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey]
      ),
      urls.count > maximumEntries
    else { return }
    let dated = urls.map { url in
      (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
    }
    for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(urls.count - maximumEntries) {
      try? manager.removeItem(at: url)
    }
  }

  private func fileURL(for key: String) -> URL {
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent(digest)
  }
}
