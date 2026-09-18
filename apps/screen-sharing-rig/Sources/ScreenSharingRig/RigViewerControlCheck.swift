#if os(macOS)
  import ScreenSharing
  import ScreenSharingWebRTC
  import Foundation
  import ScreenSharingRigKit

  /// Drives the viewer side of the product's control protocol once: request → grant → clicks → release →
  /// revoked, with heartbeats, over the real encrypted data channel. It never captures local input.
  @MainActor
  final class RigViewerControlCheck {
    private let channel: ScreenSharingControlChannel
    private let request: RigControlCheckRequest
    private let requestID = UUID()
    private var lease: UUID?
    private var deniedReason: String?
    private var revokedReason: String?
    private var clicksSent = 0
    private var keysSent = 0
    private var granted: CheckedContinuation<Void, any Error>?
    private var revoked: CheckedContinuation<Void, Never>?
    private var grantDeadline: Task<Void, Never>?
    private var revokeDeadline: Task<Void, Never>?

    init(channel: ScreenSharingControlChannel, request: RigControlCheckRequest) {
      self.channel = channel
      self.request = request
    }

    /// Runs the whole exchange; `responses` reads the host's workload counter before and after.
    func run(responses: () async -> Int?) async throws -> RigControlCheckResponse {
      defer { channel.onMessage = nil }
      channel.onMessage = { [weak self] message in self?.receive(message) }
      guard channel.isAvailable, channel.send(.request(id: requestID)) else {
        throw ScreenSharingError.unavailable("The control channel is not open.")
      }
      do {
        // A plain Task inherits this class's main-actor isolation; the continuation is resumed by the
        // grant, the denial, or this deadline, whichever comes first.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
          granted = continuation
          grantDeadline = Task {
            try? await Task.sleep(for: .seconds(5))
            self.granted?.resume(throwing: ScreenSharingError.unavailable("No grant within 5 s."))
            self.granted = nil
          }
        }
        grantDeadline?.cancel()
      } catch {
        grantDeadline?.cancel()
        if let deniedReason {
          return RigControlCheckResponse(
            granted: false, deniedReason: deniedReason, clicksSent: 0, responsesBefore: nil, responsesAfter: nil,
            revokedReason: nil)
        }
        throw error
      }
      guard let lease else { throw ScreenSharingError.unavailable("Granted without a lease.") }
      let before = await responses()
      for (sequence, event) in RigControlCheckPlan.events(
        clicks: request.clicks, keys: request.keys, x: request.x, y: request.y)
      {
        guard channel.send(.input(lease: lease, sequence: sequence, event: event)) else {
          throw ScreenSharingError.unavailable("The control channel refused input.")
        }
        if case .button(_, _, let down, _, _) = event, !down { clicksSent += 1 }
        if case .key(_, let down, _, _) = event, !down { keysSent += 1 }
        try await Task.sleep(for: .milliseconds(60))
      }
      _ = channel.send(.heartbeat(lease: lease))
      try await Task.sleep(for: .seconds(1))
      let after = await responses()
      _ = channel.send(.release(lease: lease))
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        revoked = continuation
        revokeDeadline = Task {
          try? await Task.sleep(for: .seconds(3))
          self.revoked?.resume()
          self.revoked = nil
        }
      }
      revokeDeadline?.cancel()
      return RigControlCheckResponse(
        granted: true, deniedReason: nil, clicksSent: clicksSent, keysSent: keysSent, responsesBefore: before,
        responsesAfter: after, revokedReason: revokedReason)
    }

    private func receive(_ message: ScreenSharingControlMessage) {
      switch message {
      case .grant(let request, let lease) where request == requestID:
        self.lease = lease
        granted?.resume()
        granted = nil
      case .denied(let request, let reason) where request == requestID:
        deniedReason = reason
        granted?.resume(throwing: ScreenSharingError.unavailable(reason))
        granted = nil
      case .revoked(let lease, let reason) where lease == self.lease:
        revokedReason = reason
        revoked?.resume()
        revoked = nil
      default: break
      }
    }
  }
#endif
