import CodevisorUI
import Foundation

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
    while order.count > 16 { remove(paneId: order[0]) }
    return model
  }

  func remove(paneId: UUID) {
    models.removeValue(forKey: paneId)
    order.removeAll { $0 == paneId }
  }
}
