import Foundation
import ScreenSharingPane

@MainActor
final class ScreenSharingPaneCache {
  static let shared = ScreenSharingPaneCache()
  private var models: [UUID: ScreenSharingPaneModel] = [:]
  private var order: [UUID] = []

  func model(for id: UUID, make: () -> ScreenSharingPaneModel) -> ScreenSharingPaneModel {
    let model = models[id] ?? make()
    models[id] = model
    order.removeAll { $0 == id }
    order.append(id)
    while order.count > 4 { remove(paneId: order[0]) }
    return model
  }

  func remove(paneId: UUID) {
    models.removeValue(forKey: paneId)?.closed()
    order.removeAll { $0 == paneId }
  }
}
