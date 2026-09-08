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
  @ObservationIgnored private var observer: (any NSObjectProtocol)?

  private init() {
    observer = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { Self.shared.trim(to: 1) }
    }
  }

  func model(for id: UUID, make: () -> BrowserPaneModel) -> BrowserPaneModel {
    let model = models[id] ?? make()
    model.onFaviconChange = { [weak self] image in self?.storeFavicon(image, paneId: id) }
    models[id] = model
    order.removeAll { $0 == id }
    order.append(id)
    trim(to: 4)
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

  private func trim(to capacity: Int) {
    while order.count > capacity { evictModel(paneId: order[0]) }
  }

  func capturePreview(paneId: UUID, completion: @escaping @MainActor (UIImage) -> Void) {
    guard let view = models[paneId]?.webView, view.bounds.width > 0 else { return }
    view.takeSnapshot(with: nil) { image, _ in
      guard let image else { return }
      MainActor.assumeIsolated { completion(image) }
    }
  }
}
