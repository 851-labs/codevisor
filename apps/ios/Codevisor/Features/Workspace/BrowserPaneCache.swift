import CodevisorUI
import UIKit
import WebKit

/// Keep recent pages alive across pane switches, bounded on memory-constrained devices.
@MainActor
@Observable
final class BrowserPaneCache {
  static let shared = BrowserPaneCache()
  @ObservationIgnored private var models: [UUID: BrowserPaneModel] = [:]
  private var favicons: [UUID: UIImage] = [:]
  @ObservationIgnored private var faviconOrder: [UUID] = []
  @ObservationIgnored private var order: [UUID] = []
  private init() {}

  func model(for id: UUID, make: () -> BrowserPaneModel) -> BrowserPaneModel {
    let model = models[id] ?? make()
    model.onFaviconChange = { [weak self] image in self?.storeFavicon(image, paneId: id) }
    models[id] = model
    order.removeAll { $0 == id }
    order.append(id)
    // BrowserPageRetention owns the live-page budget. Keep lightweight models
    // so eviction doesn't invalidate a SwiftUI view or lose its last location.
    while order.count > 128,
      let oldest = order.first(where: {
        $0 != id && models[$0]?.hasLiveBrowserPage == false && models[$0]?.protectsBrowserPage == false
      })
    { evictModel(paneId: oldest) }
    return model
  }

  func remove(paneId: UUID) {
    storeFavicon(nil, paneId: paneId)
    evictModel(paneId: paneId)
  }

  private func evictModel(paneId: UUID) {
    order.removeAll { $0 == paneId }
    models.removeValue(forKey: paneId)?.teardown()
  }

  func localTitle(paneId: UUID) -> String? {
    models[paneId]?.title
  }

  func favicon(paneId: UUID) -> UIImage? { favicons[paneId] }

  private func storeFavicon(_ image: CGImage?, paneId: UUID) {
    favicons[paneId] = image.map { UIImage(cgImage: $0) }
    faviconOrder.removeAll { $0 == paneId }
    if image != nil { faviconOrder.append(paneId) }
    while faviconOrder.count > 128 { favicons.removeValue(forKey: faviconOrder.removeFirst()) }
  }
}
