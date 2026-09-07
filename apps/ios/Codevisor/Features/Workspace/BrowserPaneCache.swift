import CodevisorUI
import UIKit
import WebKit

/// Keep recent pages alive across pane switches, bounded on memory-constrained devices.
@MainActor
final class BrowserPaneCache {
  static let shared = BrowserPaneCache()
  private var models: [UUID: BrowserPaneModel] = [:]
  private var order: [UUID] = []
  private var observer: (any NSObjectProtocol)?

  private init() {
    observer = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { Self.shared.trim(to: 1) }
    }
  }

  func model(for id: UUID, make: () -> BrowserPaneModel) -> BrowserPaneModel {
    let model = models[id] ?? make()
    models[id] = model
    order.removeAll { $0 == id }
    order.append(id)
    trim(to: 4)
    return model
  }

  func remove(paneId: UUID) {
    order.removeAll { $0 == paneId }
    models.removeValue(forKey: paneId)?.teardown()
  }

  func localTitle(paneId: UUID) -> String? {
    models[paneId]?.title
  }

  private func trim(to capacity: Int) {
    while order.count > capacity { remove(paneId: order[0]) }
  }

  func capturePreview(paneId: UUID, completion: @escaping @MainActor (UIImage) -> Void) {
    guard let view = models[paneId]?.webView, view.bounds.width > 0 else { return }
    view.takeSnapshot(with: nil) { image, _ in
      guard let image else { return }
      MainActor.assumeIsolated { completion(image) }
    }
  }
}
