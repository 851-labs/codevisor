import CodevisorScreenSharing
import Foundation

/// The data-plane half of a control lease: numbers each captured input event
/// and puts it on the control channel under the active lease. Runs at input
/// rate, so it is a plain object driven by closures, not a reducer. A send the
/// channel refuses ends forwarding and reports the loss once; the lease's
/// state machine decides what to do about it.
@MainActor
final class ScreenSharingInputForwarder {
  private(set) var lease: UUID?
  private var sequence: UInt64 = 0
  private let send: (ScreenSharingControlMessage) -> Bool
  var onLost: ((String?) -> Void)?

  init(send: @escaping (ScreenSharingControlMessage) -> Bool) { self.send = send }

  var isActive: Bool { lease != nil }

  func begin(lease: UUID) {
    self.lease = lease
    sequence = 0
  }

  func end() { lease = nil }

  func forward(_ event: ScreenSharingInputEvent) {
    guard let lease, event.isValid else { return }
    guard sequence < UInt64.max else {
      end()
      onLost?(nil)
      return
    }
    sequence += 1
    if !send(.input(lease: lease, sequence: sequence, event: event)) {
      end()
      onLost?("Control paused because the connection could not keep up. Request control again.")
    }
  }
}
