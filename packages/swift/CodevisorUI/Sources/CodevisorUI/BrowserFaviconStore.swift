import CodevisorClient
import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
public final class BrowserFaviconStore {
  public static let shared = BrowserFaviconStore(
    directory: CodevisorAppVariant.cacheURL().appendingPathComponent("BrowserFavicons", isDirectory: true))

  private static let memoryLimit = 256

  private var images: [String: CGImage] = [:]
  @ObservationIgnored private var recent: [String] = []
  @ObservationIgnored private var origins: [String: String] = [:]
  @ObservationIgnored private var loading: Set<String> = []
  @ObservationIgnored private let disk: BrowserFaviconDisk

  init(directory: URL) {
    disk = BrowserFaviconDisk(directory: directory)
    Task { [weak self, disk] in self?.mergeOrigins(await disk.originReferences()) }
  }

  public func image(_ reference: String?) -> CGImage? {
    reference.flatMap { images[$0] }
  }

  func reference(forPage page: String?) -> String? {
    BrowserFaviconOrigin.of(page).flatMap { origins[$0] }
  }

  public nonisolated static func sameOrigin(_ page: String?, _ other: String?) -> Bool {
    BrowserFaviconOrigin.of(page) == BrowserFaviconOrigin.of(other)
  }

  public func load(_ reference: String?, from client: (any BrowserFaviconClienting)?) async {
    guard let reference, images[reference] == nil, loading.insert(reference).inserted else { return }
    defer { loading.remove(reference) }

    if let stored = await stored(reference) {
      remember(stored)
      _ = await upload(stored, to: client)
      return
    }

    guard let downloaded = await downloaded(reference, from: client) else { return }
    remember(downloaded)
  }

  public func save(png: Data, page: String, client: any BrowserFaviconClienting) async -> String? {
    guard let favicon = await BrowserFavicon.decoding(png) else { return nil }

    return await save(favicon, page: page, client: client)
  }

  public func save(image: CGImage, page: String, client: any BrowserFaviconClienting) async -> String? {
    guard let favicon = await BrowserFavicon.encoding(image) else { return nil }

    return await save(favicon, page: page, client: client)
  }

  public func share(_ reference: String, with client: any BrowserFaviconClienting) async -> String? {
    guard let favicon = await stored(reference), await upload(favicon, to: client) else { return nil }

    return reference
  }

  private func save(_ favicon: BrowserFavicon, page: String, client: any BrowserFaviconClienting) async -> String? {
    remember(favicon)
    await disk.store(favicon.png, reference: favicon.reference)
    await recordOrigin(of: page, reference: favicon.reference)
    guard await upload(favicon, to: client) else { return nil }

    return favicon.reference
  }

  private func upload(_ favicon: BrowserFavicon, to client: (any BrowserFaviconClienting)?) async -> Bool {
    guard let client else { return false }

    do {
      try await client.publishBrowserFavicon(sha256: favicon.reference, png: favicon.png)
      return true
    } catch {
      return false
    }
  }

  private func stored(_ reference: String) async -> BrowserFavicon? {
    guard let png = await disk.png(reference) else { return nil }

    return await verified(png, reference: reference)
  }

  private func downloaded(_ reference: String, from client: (any BrowserFaviconClienting)?) async -> BrowserFavicon? {
    guard let png = try? await client?.browserFavicon(sha256: reference),
      let favicon = await verified(png, reference: reference)
    else { return nil }

    await disk.store(png, reference: reference)
    return favicon
  }

  private func verified(_ png: Data, reference: String) async -> BrowserFavicon? {
    guard let favicon = await BrowserFavicon.decoding(png), favicon.reference == reference else { return nil }

    return favicon
  }

  private func recordOrigin(of page: String, reference: String) async {
    guard let origin = BrowserFaviconOrigin.of(page) else { return }

    origins[origin] = reference
    await disk.record(reference, origin: origin)
  }

  private func mergeOrigins(_ stored: [String: String]) {
    origins.merge(stored) { current, _ in current }
  }

  private func remember(_ favicon: BrowserFavicon) {
    images[favicon.reference] = favicon.image
    recent.removeAll { $0 == favicon.reference }
    recent.append(favicon.reference)
    while recent.count > Self.memoryLimit { images.removeValue(forKey: recent.removeFirst()) }
  }
}
