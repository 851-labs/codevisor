import Foundation
import ScreenSharing

@MainActor
public final class ScreenSharingV2SessionRouter {
  public struct Ticket: Hashable, Sendable {
    let endpointId: String
    let token: String
    let id = UUID()
  }

  private enum Slot {
    case waiting(CheckedContinuation<any ScreenSharingV2Connection, any Error>?)
    case arrived(any ScreenSharingV2Connection)
  }

  public static let helloTimeout: Duration = .seconds(10)
  private var slots: [String: (ticket: Ticket, slot: Slot)] = [:]

  public init() {}

  public func expect(endpointId: String, token: String) -> Ticket {
    let ticket = Ticket(endpointId: endpointId, token: token)
    if case .waiting(let continuation)? = slots[token]?.slot { continuation?.resume(throwing: CancellationError()) }
    slots[token] = (ticket, .waiting(nil))
    return ticket
  }

  public func connection(_ ticket: Ticket, timeout: Duration) async throws -> any ScreenSharingV2Connection {
    let expiry = Task { [weak self] in
      try? await Task.sleep(for: timeout)
      self?.fail(ticket, ScreenSharingError.unavailable("The viewer didn't connect over engine v2."))
    }
    defer { expiry.cancel() }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard let entry = slots[ticket.token], entry.ticket == ticket else {
          return continuation.resume(throwing: CancellationError())
        }

        switch entry.slot {
        case .arrived(let connection):
          slots.removeValue(forKey: ticket.token)
          continuation.resume(returning: connection)
        case .waiting:
          slots[ticket.token] = (ticket, .waiting(continuation))
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.fail(ticket, CancellationError()) }
    }
  }

  public func deliver(_ connection: any ScreenSharingV2Connection) async {
    guard slots.values.contains(where: { $0.ticket.endpointId == connection.remoteId }) else {
      connection.close("no screen-sharing session expects this viewer")
      return
    }

    let deadline = Task {
      try await Task.sleep(for: Self.helloTimeout)
      connection.close("the viewer didn't say which screen-sharing session it wants")
    }
    defer { deadline.cancel() }
    guard let stream = try? await connection.acceptStream(), let hello = try? await stream.receive(),
      let token = ScreenSharingV2Hello.token(in: hello), let entry = slots[token],
      entry.ticket.endpointId == connection.remoteId, case .waiting = entry.slot
    else {
      connection.close("no screen-sharing session expects this viewer")
      return
    }

    hand(ScreenSharingV2HandedConnection(connection, first: stream, hello: hello), to: entry.ticket)
  }

  public func connectLocally(token: String) -> (any ScreenSharingV2Connection)? {
    guard let entry = slots[token], case .waiting = entry.slot else { return nil }

    let (host, viewer) = ScreenSharingV2LocalConnection.pair(endpointId: entry.ticket.endpointId)
    hand(host, to: entry.ticket)
    return viewer
  }

  private func hand(_ connection: any ScreenSharingV2Connection, to ticket: Ticket) {
    guard let entry = slots[ticket.token], entry.ticket == ticket, case .waiting(let continuation) = entry.slot else {
      connection.close("the screen-sharing session ended")
      return
    }
    guard let continuation else {
      slots[ticket.token] = (ticket, .arrived(connection))
      return
    }

    slots.removeValue(forKey: ticket.token)
    continuation.resume(returning: connection)
  }

  private func fail(_ ticket: Ticket, _ error: any Error) {
    guard let entry = slots[ticket.token], entry.ticket == ticket else { return }

    slots.removeValue(forKey: ticket.token)
    switch entry.slot {
    case .waiting(let continuation): continuation?.resume(throwing: error)
    case .arrived(let connection): connection.close("the screen-sharing session ended")
    }
  }
}

private final class ScreenSharingV2HandedConnection: ScreenSharingV2Connection, @unchecked Sendable {
  private let base: any ScreenSharingV2Connection
  private var first: (any ScreenSharingV2MessageStream)?

  init(_ base: any ScreenSharingV2Connection, first: any ScreenSharingV2MessageStream, hello: Data) {
    self.base = base
    self.first = ReplayedStream(first, hello: hello)
  }

  var remoteId: String { base.remoteId }
  var route: ScreenSharingV2Route? { base.route }
  func openStream() async throws -> any ScreenSharingV2MessageStream { try await base.openStream() }

  func acceptStream() async throws -> any ScreenSharingV2MessageStream {
    if let first {
      self.first = nil
      return first
    }

    return try await base.acceptStream()
  }

  func openMedia() async -> any ScreenSharingMediaTransport { await base.openMedia() }
  func mediaStatistics() -> [String: String] { base.mediaStatistics() }
  func closed() async -> String { await base.closed() }
  func close(_ reason: String) { base.close(reason) }
}

private final class ReplayedStream: ScreenSharingV2MessageStream, @unchecked Sendable {
  private let base: any ScreenSharingV2MessageStream
  private var hello: Data?

  init(_ base: any ScreenSharingV2MessageStream, hello: Data) {
    self.base = base
    self.hello = hello
  }

  func send(_ payload: Data) async throws { try await base.send(payload) }

  func receive() async throws -> Data? {
    if let hello {
      self.hello = nil
      return hello
    }

    return try await base.receive()
  }

  func finish() async { await base.finish() }
}
