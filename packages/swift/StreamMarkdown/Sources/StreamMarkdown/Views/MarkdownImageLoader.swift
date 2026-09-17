import Foundation
import ImageIO
import Observation
import SwiftUI

#if canImport(AppKit)
  import AppKit
  public typealias MarkdownPlatformImage = NSImage
#elseif canImport(UIKit)
  import UIKit
  public typealias MarkdownPlatformImage = UIImage
#endif

/// Immutable decoded pixels. The identity includes the host's file version and
/// namespace, so render caches cannot mix identical paths from different servers.
public struct MarkdownImage: Hashable, @unchecked Sendable {
  public let image: MarkdownPlatformImage
  public let id: String

  public init(image: MarkdownPlatformImage, id: String) {
    self.image = image
    self.id = id
  }

  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
  public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum MarkdownImageResource: Hashable, Sendable {
  case loaded(MarkdownImage)
  case unavailable
}

/// A host supplies authenticated local/attachment loading; standalone Markdown
/// can load ordinary HTTP images through the default provider.
public final class MarkdownImageLoader: Sendable {
  public let id: String
  private let fetch: @MainActor @Sendable (String) async -> MarkdownImage?

  public init(id: String, fetch: @escaping @MainActor @Sendable (String) async -> MarkdownImage?) {
    self.id = id
    self.fetch = fetch
  }

  @MainActor public func image(for source: String) async -> MarkdownImage? { await fetch(source) }

  public static let remote = MarkdownImageLoader(id: "http", fetch: fetchRemote)

  @MainActor private static var activeDownloads = 0
  @MainActor private static var downloadWaiters: [CheckedContinuation<Bool, Never>] = []

  @MainActor private static func acquireDownload() async -> Bool {
    if activeDownloads < 4 { activeDownloads += 1; return true }
    guard downloadWaiters.count < 64 else { return false }
    return await withCheckedContinuation { downloadWaiters.append($0) }
  }

  @MainActor private static func releaseDownload() {
    if downloadWaiters.isEmpty { activeDownloads -= 1 } else { downloadWaiters.removeFirst().resume(returning: true) }
  }

  @MainActor private static func fetchRemote(_ source: String) async -> MarkdownImage? {
    guard let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
      return nil
    }
    guard await acquireDownload() else { return nil }
    defer { releaseDownload() }
    do {
      try Task.checkCancellation()
      let (file, response) = try await URLSession.shared.download(from: url)
      defer { try? FileManager.default.removeItem(at: file) }
      guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { return nil }
      return await Task.detached(priority: .userInitiated) {
        guard
          let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let pixels = CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: 1280,
            ] as CFDictionary)
        else { return nil as MarkdownImage? }
        #if canImport(AppKit)
          let image = NSImage(cgImage: pixels, size: NSSize(width: pixels.width, height: pixels.height))
        #else
          let image = UIImage(cgImage: pixels)
        #endif
        return MarkdownImage(image: image, id: UUID().uuidString)
      }.value
    } catch { return nil }
  }
}

extension EnvironmentValues {
  @Entry public var markdownImageLoader: MarkdownImageLoader = .remote
}

@MainActor
@Observable
final class MarkdownTableImages {
  private(set) var resources: [String: MarkdownImageResource] = [:] {
    didSet { if oldValue != resources { onChange?() } }
  }
  @ObservationIgnored var onChange: (() -> Void)?
  @ObservationIgnored private var loaderID: String?
  @ObservationIgnored private var generation = 0

  struct Request: Hashable {
    let sources: Set<String>
    let loaderID: String
  }

  func load(sources: Set<String>, using loader: MarkdownImageLoader) async {
    generation += 1
    let generation = generation
    if loaderID != loader.id {
      loaderID = loader.id
      resources = [:]
    }
    resources = resources.filter { sources.contains($0.key) }
    let pending = sources.filter {
      if case .loaded = resources[$0] { return false }
      return true
    }.sorted()
    await withTaskGroup(of: (String, MarkdownImage?).self) { group in
      var next = 0
      func enqueue() {
        guard next < pending.count else { return }
        let source = pending[next]
        next += 1
        group.addTask { (source, await loader.image(for: source)) }
      }
      for _ in 0..<min(4, pending.count) { enqueue() }
      for await (source, image) in group {
        guard !Task.isCancelled, self.generation == generation else { group.cancelAll(); return }
        resources[source] = image.map(MarkdownImageResource.loaded) ?? .unavailable
        enqueue()
      }
    }
  }
}
