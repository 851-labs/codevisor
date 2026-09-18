import ScreenSharing
import ScreenSharingWebRTC
import Foundation

/// Real encrypted data-channel check with a recording sink. Never posts input
/// to the diagnostic machine. Exercises both directions while video is running.
@MainActor
final class ProbeControlCheck {
  private let host: ScreenSharingControlChannel
  private let viewer: ScreenSharingControlChannel
  private let request = UUID()
  private let lease = UUID()
  private var started = false
  private var received: [ScreenSharingInputEvent] = []
  private var completion: CheckedContinuation<Void, any Error>?
  private var timeout: Task<Void, Never>?
  private let events: [ScreenSharingInputEvent] = [
    .move(.init(x: 0.25, y: 0.75), modifiers: 0),
    .button(.init(x: 0.25, y: 0.75), button: 0, down: true, clicks: 1, modifiers: 0),
    .move(.init(x: 0.5, y: 0.5), modifiers: 0),
    .button(.init(x: 0.5, y: 0.5), button: 0, down: false, clicks: 1, modifiers: 0),
    .key(code: 0, down: true, repeatKey: false, modifiers: 0),
    .key(code: 0, down: false, repeatKey: false, modifiers: 0),
    .scroll(.init(x: 0.5, y: 0.5), x: -3, y: 12, modifiers: 0),
    .text("Codevisor café 日本語"),
  ]
  init(host: ScreenSharingControlChannel, viewer: ScreenSharingControlChannel) {
    self.host = host; self.viewer = viewer
  }
  func run() async throws {
    defer {
      timeout?.cancel()
      host.onMessage = nil; viewer.onMessage = nil
      host.onAvailabilityChanged = nil; viewer.onAvailabilityChanged = nil
    }
    try await withCheckedThrowingContinuation { continuation in
      completion = continuation
      host.onAvailabilityChanged = { [weak self] _ in self?.startIfReady() }
      viewer.onAvailabilityChanged = { [weak self] _ in self?.startIfReady() }
      host.onMessage = { [weak self] in self?.hostReceive($0) }
      viewer.onMessage = { [weak self] in self?.viewerReceive($0) }
      timeout = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        self?.finish(false)
      }
      startIfReady()
    }
  }
  private func startIfReady() {
    guard !started, host.isAvailable, viewer.isAvailable else { return }
    started = true
    if !viewer.send(.request(id: request)) { finish(false) }
  }
  private func hostReceive(_ message: ScreenSharingControlMessage) {
    switch message {
    case .request(let id) where id == request:
      if !host.send(.grant(request: request, lease: lease)) { finish(false) }
    case .input(let id, let sequence, let event) where id == lease:
      guard sequence == UInt64(received.count + 1) else { finish(false); return }
      received.append(event)
    case .release(let id) where id == lease:
      guard received == events else { finish(false); return }
      if !host.send(.revoked(lease: lease, reason: "complete")) { finish(false) }
    default: finish(false)
    }
  }
  private func viewerReceive(_ message: ScreenSharingControlMessage) {
    switch message {
    case .grant(let request, let lease) where request == self.request && lease == self.lease:
      for (index, event) in events.enumerated() {
        guard viewer.send(.input(lease: lease, sequence: UInt64(index + 1), event: event)) else {
          finish(false); return
        }
      }
      if !viewer.send(.release(lease: lease)) { finish(false) }
    case .revoked(let lease, let reason) where lease == self.lease && reason == "complete": finish(true)
    default: finish(false)
    }
  }
  private func finish(_ passed: Bool) {
    guard let completion else { return }
    self.completion = nil
    if passed {
      completion.resume()
    } else {
      completion.resume(throwing: ScreenSharingError.unavailable("Control channel check failed."))
    }
  }
}
