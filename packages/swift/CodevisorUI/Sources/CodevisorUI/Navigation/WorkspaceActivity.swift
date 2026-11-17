import Foundation
import Observation

@MainActor
@Observable
public final class WorkspaceActivity {
  public private(set) var isActive: Bool
  @ObservationIgnored private var listeners: [UUID: (Bool) -> Void] = [:]

  public init(isActive: Bool) {
    self.isActive = isActive
  }

  public func setActive(_ active: Bool) {
    guard active != isActive else { return }

    isActive = active
    for listener in listeners.values {
      listener(active)
    }
  }

  public func addListener(_ id: UUID, _ listener: @escaping (Bool) -> Void) {
    listeners[id] = listener
  }

  public func removeListener(_ id: UUID) {
    listeners[id] = nil
  }
}
