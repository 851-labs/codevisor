import CodevisorCore
import CryptoKit
import ImageIO
import SwiftUI

public struct ToolCallIconView: View {
  let icon: ToolCallIcon

  @Environment(\.transcriptController) private var controller
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.toolIconSide) private var side

  public init(icon: ToolCallIcon) {
    self.icon = icon
  }

  public var body: some View {
    ToolArtworkImage(
      request: icon.artwork.flatMap { artwork in
        controller.map {
          ToolIconImages.Request(
            namespace: $0.toolIconCacheNamespace, artwork: artwork, dark: colorScheme == .dark)
        }
      },
      side: icon.artwork.map { ToolIconKind(artwork: $0).size(in: side) } ?? side,
      fetch: { [weak controller] request in
        guard let controller else { throw SessionControllerError.serverUnavailable }
        return try await controller.toolIconData(request)
      }
    ) {
      ToolIconGlyph(symbol: icon.symbol)
        .foregroundStyle(.secondary)
    }
    .accessibilityHidden(true)
  }
}

struct ToolArtworkImage<Placeholder: View>: View {
  let request: ToolIconImages.Request?
  let side: CGFloat
  let fetch: ToolIconImages.Fetch
  @ViewBuilder let placeholder: Placeholder

  @Environment(\.colorScheme) private var colorScheme
  @State private var loaded: LoadedArtwork?

  var body: some View {
    let artwork = request.flatMap {
      loaded?.request == $0 ? loaded?.artwork : ToolIconImages.memoryArtwork(for: $0)
    }
    Group {
      if let artwork {
        let plated = artwork.isDark && colorScheme == .dark
        artworkImage(artwork.image)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .padding(plated ? side / 10 : 0)
          .frame(width: side, height: side)
          .background {
            if plated { RoundedRectangle(cornerRadius: side / 4, style: .continuous).fill(.white.opacity(0.9)) }
          }
          .clipShape(RoundedRectangle(cornerRadius: side / 4, style: .continuous))
      } else {
        placeholder
      }
    }
    .task(id: request) {
      guard let request, loaded?.request != request else { return }
      let artwork = await ToolIconImages.artwork(for: request, fetch: fetch)
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

struct ToolIconArtwork {
  let image: OSImage
  let isDark: Bool
}

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
      case let .app(bundleId, _):
        return "\(namespace)|app|\(bundleId)"
      }
    }

    var serverRequest: ServerToolIconRequest {
      switch artwork {
      case let .site(origin): .site(origin: origin, dark: dark)
      case let .mcpServer(id, host): .mcpServer(id: id, host: host, dark: dark)
      case let .app(bundleId, path): .app(bundleId: bundleId, path: path)
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
      await disk.storeMissing(key: key)
      memory.setObject(Box(artwork: fallback, expiresAt: .now.addingTimeInterval(60)), forKey: key as NSString)
      return fallback
    } catch {
      memory.setObject(Box(artwork: fallback, expiresAt: .now.addingTimeInterval(30)), forKey: key as NSString)
      return fallback
    }
  }

  private static func decode(_ data: Data) async -> ToolIconArtwork? {
    let decoded = await Task.detached(priority: .utility) { () -> (CGImage, Bool)? in
      ToolIconArtworkDecoder.decode(data)
    }.value
    guard let (cgImage, isDark) = decoded else { return nil }
    #if os(macOS)
      let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    #else
      let image = UIImage(cgImage: cgImage)
    #endif
    return ToolIconArtwork(image: image, isDark: isDark)
  }

}

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
    }
    writes += 1
    if writes % 64 == 0 { trim() }
  }

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
