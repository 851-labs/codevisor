import Foundation
import Observation

@MainActor
@Observable
public final class WorkspaceActivity {
  public private(set) var isActive: Bool
  @ObservationIgnored private var listeners: [(id: UUID, notify: (Bool) -> Void)] = []

  public init(isActive: Bool) {
    self.isActive = isActive
  }

  public func setActive(_ active: Bool, notifiesListeners: Bool) {
    guard active != isActive else { return }

    isActive = active
    guard notifiesListeners else { return }

    if active {
      DeferredPaneFocus.attemptingNow { notify(active) }
    } else {
      notify(active)
    }
  }

  public func addListener(_ id: UUID, _ listener: @escaping (Bool) -> Void) {
    removeListener(id)
    listeners.append((id, listener))
  }

  public func removeListener(_ id: UUID) {
    listeners.removeAll { $0.id == id }
  }

  private func notify(_ active: Bool) {
    for listener in listeners {
      listener.notify(active)
    }
  }
}
