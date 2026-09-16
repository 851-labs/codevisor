import CodevisorUI
import Foundation

/// The toolbar and pane resolve the same presentation state across navigation.
@MainActor
final class FilePaneCache {
  static let shared = FilePaneCache()
  private var models: [UUID: FilePaneModel] = [:]
  private var order: [UUID] = []

  func model(for id: UUID, make: () -> FilePaneModel) -> FilePaneModel {
    let model = models[id] ?? make()
    models[id] = model
    order.removeAll { $0 == id }
    order.append(id)
    while order.count > 64 { remove(paneId: order[0]) }
    return model
  }

  func remove(paneId: UUID) {
    models.removeValue(forKey: paneId)?.close()
    order.removeAll { $0 == paneId }
  }
}
