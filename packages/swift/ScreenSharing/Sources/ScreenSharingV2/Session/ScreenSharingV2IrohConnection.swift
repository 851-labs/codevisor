import CodevisorNet
import Foundation
import Synchronization

public final class ScreenSharingV2IrohConnection: ScreenSharingV2Connection, @unchecked Sendable {
  private let connection: NetConnectionHandle
  private let media = Mutex<ScreenSharingIrohMediaTransport?>(nil)

  public init(_ connection: NetConnectionHandle) {
    self.connection = connection
  }

  public var remoteId: String { connection.remoteId() }

  public var route: ScreenSharingV2Route? {
    connection.paths().first(where: \.selected).map { ScreenSharingV2Route(isRelay: $0.isRelay, roundTripMs: $0.rttMs) }
  }

  public func openStream() async throws -> any ScreenSharingV2MessageStream {
    ScreenSharingV2IrohMessageStream(try await connection.openMessageStream())
  }

  public func acceptStream() async throws -> any ScreenSharingV2MessageStream {
    ScreenSharingV2IrohMessageStream(try await connection.acceptMessageStream())
  }

  public func openMedia() async -> any ScreenSharingMediaTransport {
    let transport = ScreenSharingIrohMediaTransport(
      session: await connection.openMediaSession(config: ScreenSharingIrohMediaTransport.sessionConfig))
    media.withLock { $0 = transport }
    return transport
  }

  public func mediaStatistics() -> [String: String] {
    guard let stats = media.withLock({ $0 })?.session.stats() else { return [:] }

    return [
      "v2.bytesReceived": String(stats.bytesReceived), "v2.bytesSent": String(stats.bytesSent),
      "v2.framesReceived": String(stats.framesReceived), "v2.framesSkipped": String(stats.framesSkipped),
      "v2.recoveredByFEC": String(stats.fecRecoveries), "v2.nacksSent": String(stats.nacksSent),
      "v2.lossPercent": String(stats.lossPercent), "v2.estimateKbps": String(stats.estimateKbps),
    ]
  }

  public func closed() async -> String {
    await connection.closed()
  }

  public func close(_ reason: String) {
    connection.close(code: 0, reason: reason)
  }
}

final class ScreenSharingV2IrohMessageStream: ScreenSharingV2MessageStream, @unchecked Sendable {
  private let stream: NetMessageStreamHandle

  init(_ stream: NetMessageStreamHandle) {
    self.stream = stream
  }

  func send(_ payload: Data) async throws {
    try await stream.send(kind: 1, payload: payload)
  }

  func receive() async throws -> Data? {
    try await stream.recv()?.payload
  }

  func finish() async {
    try? await stream.finish()
  }
}
