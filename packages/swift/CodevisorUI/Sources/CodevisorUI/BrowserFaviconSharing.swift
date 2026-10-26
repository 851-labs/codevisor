import CodevisorClient
import CoreGraphics
import Foundation

@MainActor
public final class BrowserFaviconSharing {
  public var onShare: ((String, String) -> Void)?
  private let client: any BrowserFaviconClienting
  private let store: BrowserFaviconStore

  public init(client: any BrowserFaviconClienting, store: BrowserFaviconStore = .shared) {
    self.client = client
    self.store = store
  }

  @discardableResult
  public func pageLoaded(_ page: String) -> Task<Void, Never>? {
    guard let reference = store.reference(forPage: page) else { return nil }

    return share(for: page) { store, client in await store.share(reference, with: client) }
  }

  @discardableResult
  public func iconLoaded(png: Data, page: String) -> Task<Void, Never> {
    share(for: page) { store, client in await store.save(png: png, page: page, client: client) }
  }

  @discardableResult
  public func iconLoaded(image: CGImage, page: String) -> Task<Void, Never> {
    share(for: page) { store, client in await store.save(image: image, page: page, client: client) }
  }

  private func share(
    for page: String,
    _ upload: @escaping @MainActor (BrowserFaviconStore, any BrowserFaviconClienting) async -> String?
  ) -> Task<Void, Never> {
    Task { [weak self, store, client] in
      guard let reference = await upload(store, client) else { return }
      self?.onShare?(reference, page)
    }
  }
}
