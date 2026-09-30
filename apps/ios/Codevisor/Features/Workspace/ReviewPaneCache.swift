import CodevisorUI
import Foundation

/// The toolbar and pane resolve the same Review state, and a loaded diff
/// survives switching tabs.
@MainActor
final class ReviewPaneCache {
  static let shared = ReviewPaneCache()
  private var models: [UUID: ReviewPaneModel] = [:]
  private var order: [UUID] = []

  func model(for id: UUID, make: () -> ReviewPaneModel) -> ReviewPaneModel {
    let model = models[id] ?? make()
    models[id] = model
    order.removeAll { $0 == id }
    order.append(id)
    // Loaded diffs carry whole file texts, so keep fewer than file panes.
    while order.count > 16 { remove(paneId: order[0]) }
    return model
  }

  func remove(paneId: UUID) {
    models.removeValue(forKey: paneId)
    order.removeAll { $0 == paneId }
  }
}
