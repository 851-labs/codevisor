import Foundation
import SimulatorPane

/// A Simulator pane's model outlives tab switches; its stream stops while the pane is hidden.
@MainActor
final class SimulatorPaneCache {
  static let shared = SimulatorPaneCache()
  private var models: [UUID: SimulatorPaneModel] = [:]
  private var order: [UUID] = []

  func model(for id: UUID, make: () -> SimulatorPaneModel) -> SimulatorPaneModel {
    let model = models[id] ?? make()
    models[id] = model
    order.removeAll { $0 == id }
    order.append(id)
    while order.count > 8 { remove(paneId: order[0]) }
    return model
  }

  func remove(paneId: UUID) {
    models.removeValue(forKey: paneId)?.closed()
    order.removeAll { $0 == paneId }
  }
}
