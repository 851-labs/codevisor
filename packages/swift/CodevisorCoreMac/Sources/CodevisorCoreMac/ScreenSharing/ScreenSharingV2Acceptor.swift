import CodevisorNet
import Foundation
import ScreenSharing

@MainActor
final class ScreenSharingV2Acceptor {
  static let shared = ScreenSharingV2Acceptor()

  private var endpoint: NetEndpointHandle?
  private var loop: Task<Void, Never>?
  private var waiting: [String: (id: UUID, continuation: CheckedContinuation<NetConnectionHandle, any Error>)] = [:]

  func connection(
    from endpointId: String, on endpoint: NetEndpointHandle, timeout: Duration
  ) async throws
    -> NetConnectionHandle
  {
    listen(on: endpoint)
    let id = UUID()
    let expiry = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      self?.fail(endpointId, id: id, ScreenSharingError.unavailable("The viewer didn't connect over engine v2."))
    }
    defer { expiry.cancel() }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiting.removeValue(forKey: endpointId)?.continuation.resume(throwing: CancellationError())
        waiting[endpointId] = (id, continuation)
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.fail(endpointId, id: id, CancellationError()) }
    }
  }

  private func listen(on endpoint: NetEndpointHandle) {
    guard self.endpoint !== endpoint || loop == nil else { return }

    loop?.cancel()
    self.endpoint = endpoint
    loop = Task { [weak self] in
      while true {
        let incoming: NetConnectionHandle?
        do {
          incoming = try await endpoint.accept()
        } catch {
          continue
        }
        guard let incoming, let self, !Task.isCancelled else { break }

        self.deliver(incoming)
      }
      guard let self, self.endpoint === endpoint else { return }

      self.loop = nil
      self.endpoint = nil
    }
  }

  private func deliver(_ connection: NetConnectionHandle) {
    guard let waiter = waiting.removeValue(forKey: connection.remoteId()) else {
      connection.close(code: 1, reason: "no screen-sharing session expects this viewer")
      return
    }

    waiter.continuation.resume(returning: connection)
  }

  private func fail(_ endpointId: String, id: UUID, _ error: any Error) {
    guard waiting[endpointId]?.id == id else { return }

    waiting.removeValue(forKey: endpointId)?.continuation.resume(throwing: error)
  }
}
