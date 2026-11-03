import CodevisorNet
import Foundation
import ScreenSharing

@MainActor
final class ScreenSharingV2Acceptor {
  struct Expectation: Equatable {
    let endpointId: String
    let id: UUID
  }

  private enum Slot {
    case waiting(CheckedContinuation<NetConnectionHandle, any Error>?)
    case arrived(NetConnectionHandle)
  }

  static let shared = ScreenSharingV2Acceptor()

  private var endpoint: NetEndpointHandle?
  private var loop: Task<Void, Never>?
  private var slots: [String: (id: UUID, slot: Slot)] = [:]

  func expect(_ endpointId: String, on endpoint: NetEndpointHandle) -> Expectation {
    listen(on: endpoint)
    let expectation = Expectation(endpointId: endpointId, id: UUID())
    if case .waiting(let continuation)? = slots[endpointId]?.slot {
      continuation?.resume(throwing: CancellationError())
    }
    slots[endpointId] = (expectation.id, .waiting(nil))
    return expectation
  }

  func connection(_ expectation: Expectation, timeout: Duration) async throws -> NetConnectionHandle {
    let expiry = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      self?.fail(expectation, ScreenSharingError.unavailable("The viewer didn't connect over engine v2."))
    }
    defer { expiry.cancel() }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard let entry = slots[expectation.endpointId], entry.id == expectation.id else {
          return continuation.resume(throwing: CancellationError())
        }

        switch entry.slot {
        case .arrived(let connection):
          slots.removeValue(forKey: expectation.endpointId)
          continuation.resume(returning: connection)
        case .waiting:
          slots[expectation.endpointId] = (entry.id, .waiting(continuation))
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.fail(expectation, CancellationError()) }
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
    let endpointId = connection.remoteId()
    guard let entry = slots[endpointId], case .waiting(let continuation) = entry.slot else {
      connection.close(code: 1, reason: "no screen-sharing session expects this viewer")
      return
    }

    guard let continuation else {
      slots[endpointId] = (entry.id, .arrived(connection))
      return
    }

    slots.removeValue(forKey: endpointId)
    continuation.resume(returning: connection)
  }

  private func fail(_ expectation: Expectation, _ error: any Error) {
    guard let entry = slots[expectation.endpointId], entry.id == expectation.id else { return }

    slots.removeValue(forKey: expectation.endpointId)
    switch entry.slot {
    case .waiting(let continuation): continuation?.resume(throwing: error)
    case .arrived(let connection): connection.close(code: 1, reason: "the screen-sharing session ended")
    }
  }
}
