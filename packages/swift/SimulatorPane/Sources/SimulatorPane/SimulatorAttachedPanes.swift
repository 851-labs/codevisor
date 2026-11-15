import Foundation
import ScreenSharingConnection

@MainActor
final class SimulatorAttachedPanes {
  private var panes: [ScreenSharingLegacyIdentity] = []

  var first: ScreenSharingLegacyIdentity? { panes.first }

  var isEmpty: Bool { panes.isEmpty }

  func add(_ pane: ScreenSharingLegacyIdentity) {
    panes.append(pane)
  }

  func remove(_ pane: ScreenSharingLegacyIdentity) {
    guard let index = panes.firstIndex(of: pane) else { return }

    panes.remove(at: index)
  }
}
