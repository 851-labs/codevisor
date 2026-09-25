import CodevisorClient
import Foundation

// MARK: - Unanswered-open recovery

extension CloudHubConnection {
  /// The owner of a channel gave up waiting for the machine's first frame.
  /// One silent channel can be a slow handler; repeated ones toward the same
  /// machine mean this hub session no longer reaches it (seen after hub
  /// restarts: the socket stays healthy while opens vanish). A fresh session
  /// — no resume, new identity, authoritative roster in the welcome — is
  /// what an app relaunch did to recover, so do that instead.
  func reportUnanswered(channelId: String) {
    guard let state = channels[channelId], !state.receivedInbound, isWelcomed else { return }
    let machineId = state.machineDeviceId
    let count = (unansweredOpens[machineId] ?? 0) + 1
    unansweredOpens[machineId] = count
    let restarts = unansweredSessionRestarts[machineId] ?? 0
    let threshold = min(
      Self.unansweredOpenThreshold << min(restarts, 8),
      Self.maximumUnansweredOpenThreshold
    )
    guard count >= threshold else { return }
    unansweredSessionRestarts[machineId] = restarts + 1
    Log.cloud.notice(
      "Machine \(machineId, privacy: .public) left \(count) channel opens unanswered; starting a fresh cloud hub session"
    )
    startFreshSession()
  }

  static let unansweredOpenThreshold = 2
  static let maximumUnansweredOpenThreshold = 16

  /// Any frame from a machine proves the relay path to it works.
  func noteInbound(from machineId: String) {
    unansweredOpens.removeValue(forKey: machineId)
    unansweredSessionRestarts.removeValue(forKey: machineId)
  }

  /// Drops the socket without offering a resume, so the next hello registers
  /// a new hub session. The run loop's teardown then fails every channel
  /// (their owners re-open from durable cursors) and reconnects.
  func startFreshSession() {
    guard let socket else { return }
    resumeToken = nil
    lastConnectionId = nil
    unansweredOpens.removeAll()
    isWelcomed = false
    resetHeartbeat()
    // Detach before cancelling: closes the owners send while the run loop
    // tears down must fail fast rather than report the socket unhealthy.
    self.socket = nil
    socketID = nil
    socket.cancel(with: .goingAway, reason: nil)
  }
}
