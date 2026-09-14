import CodevisorScreenSharing
import Foundation
import Observation

@MainActor
@Observable
public final class ScreenSharingViewerControl {
  public enum State: Equatable { case viewing, requesting, controlling }
  public private(set) var state: State = .viewing
  public private(set) var available = false
  public private(set) var message: String?
  @ObservationIgnored var onActiveChanged: ((Bool) -> Void)?
  @ObservationIgnored private let send: (ScreenSharingControlMessage) -> Bool
  @ObservationIgnored private let now: () -> TimeInterval
  @ObservationIgnored private var requestID: UUID?
  @ObservationIgnored private var deadline: TimeInterval = 0
  @ObservationIgnored private var lease: UUID?
  @ObservationIgnored private var sequence: UInt64 = 0
  @ObservationIgnored private var requestPendingAvailability = false

  init(
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    send: @escaping (ScreenSharingControlMessage) -> Bool
  ) { self.now = now; self.send = send }

  public func request() {
    guard available, state == .viewing else { return }
    requestPendingAvailability = false
    let id = UUID()
    requestID = id; deadline = now() + 3; state = .requesting; message = nil
    if !send(.request(id: id)) { release(reason: "The control channel is unavailable.") }
  }

  /// Opening a connection requests control once, after video is ready. The
  /// channel may open later; an explicit release cancels this pending request.
  func requestWhenAvailable() {
    guard state == .viewing else { return }
    requestPendingAvailability = true
    if available { request() }
  }

  public func release(reason: String? = nil) {
    requestPendingAvailability = false
    let oldLease = lease
    requestID = nil; lease = nil; state = .viewing; message = reason
    onActiveChanged?(false)
    if let oldLease { _ = send(.release(lease: oldLease)) }
  }

  func setAvailable(_ available: Bool) {
    let previouslyAvailable = self.available
    guard available != previouslyAvailable else { return }
    self.available = available
    if !available {
      release(reason: previouslyAvailable ? "Control is unavailable on this connection." : nil)
    } else if !previouslyAvailable {
      message = nil
      if requestPendingAvailability { request() }
    }
  }

  func receive(_ message: ScreenSharingControlMessage) {
    switch message {
    case .grant(let request, let id):
      guard requestID == request, state == .requesting, available, now() < deadline else {
        // Cancellation can cross the host's grant. Release that grant immediately.
        _ = send(.release(lease: id)); return
      }
      requestID = nil; lease = id; sequence = 0; state = .controlling; self.message = nil
      onActiveChanged?(true)
    case .denied(let request, let reason):
      if requestID == request { release(reason: reason) }
    case .revoked(let id, let reason):
      if lease == id { release(reason: reason) }
    default: break
    }
  }

  func tick() {
    if state == .requesting, now() >= deadline { release(reason: "The host did not grant control. Try again.") }
    if let lease, !send(.heartbeat(lease: lease)) { release(reason: "The control channel closed.") }
  }

  func input(_ event: ScreenSharingInputEvent) {
    guard let lease, state == .controlling, event.isValid else { return }
    guard sequence < UInt64.max else { release(); return }
    sequence += 1
    if !send(.input(lease: lease, sequence: sequence, event: event)) {
      release(reason: "Control paused because the connection could not keep up. Request control again.")
    }
  }
}
