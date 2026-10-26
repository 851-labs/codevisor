import CodevisorUI
import UIKit
import WebKit

@MainActor
final class BrowserPaneCache {
  static let shared = BrowserPaneCache()
  private var models: [UUID: BrowserPaneModel] = [:]
  private var order: [UUID] = []
  private init() {}

  func model(for id: UUID, make: () -> BrowserPaneModel) -> BrowserPaneModel {
    let model = models[id] ?? make()
    models[id] = model
    order.removeAll { $0 == id }
    order.append(id)
    while order.count > 128,
      let oldest = order.first(where: {
        $0 != id && models[$0]?.hasLiveBrowserPage == false && models[$0]?.protectsBrowserPage == false
      })
    { evictModel(paneId: oldest) }
    return model
  }

  func remove(paneId: UUID) {
    evictModel(paneId: paneId)
  }

  private func evictModel(paneId: UUID) {
    order.removeAll { $0 == paneId }
    models.removeValue(forKey: paneId)?.teardown()
  }

  func localTitle(paneId: UUID) -> String? {
    models[paneId]?.title
  }
}
