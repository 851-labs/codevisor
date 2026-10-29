import ScreenSharing
import ScreenSharingBench
import ScreenSharingWebRTC

@MainActor
final class LoopbackPeers {
  private static let connectTimeout = Duration.seconds(15)

  let sender: ScreenSharingSender
  let receiver: ScreenSharingReceiver
  let hostMetrics = ScreenSharingMetrics()
  let viewerMetrics = ScreenSharingMetrics()

  init(configuration: ScreenSharingVideoConfiguration) async throws {
    let sender = try await ScreenSharingSender(configuration: configuration, metrics: hostMetrics)
    do {
      receiver = try await ScreenSharingReceiver(configuration: .init(), metrics: viewerMetrics)
    } catch {
      sender.close()
      throw error
    }
    self.sender = sender
  }

  func connect(through relay: LoopbackRelay) async throws {
    let states = connectionStates()
    let offer = try await receiver.makeDescription(offer: true)
    let viewer = try LoopbackCandidates.hostAddress(in: offer.sdp)
    try await sender.accept(routed(offer, through: viewer, port: relay.viewerFacing.port))
    let answer = try await sender.makeDescription(offer: false)
    let host = try LoopbackCandidates.hostAddress(in: answer.sdp)
    relay.connect(host: host, viewer: viewer)
    try await receiver.accept(routed(answer, through: host, port: relay.hostFacing.port))
    try await Self.awaitConnected(states)
  }

  func close() async {
    sender.close()
    receiver.close()
    await sender.awaitClosed()
    await receiver.awaitClosed()
  }

  private func connectionStates() -> AsyncStream<String> {
    let (states, continuation) = AsyncStream.makeStream(of: String.self)
    sender.onConnectionChanged = { continuation.yield($0) }
    return states
  }

  private func routed(
    _ description: ScreenSharingDescription, through peer: BenchUDPAddress, port: UInt16
  ) throws -> ScreenSharingDescription {
    let relay = try BenchUDPAddress(host: peer.host, port: port)
    return ScreenSharingDescription(
      kind: description.kind, sdp: LoopbackCandidates.routed(description.sdp, through: relay))
  }

  private static func awaitConnected(_ states: AsyncStream<String>) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for await state in states {
          if state == "connected" { return }
          if state == "failed" { throw LoopbackError.connectionFailed }
        }
        throw LoopbackError.connectionFailed
      }
      group.addTask {
        try await Task.sleep(for: connectTimeout)
        throw LoopbackError.connectionTimedOut
      }
      try await group.next()
      group.cancelAll()
    }
  }
}
