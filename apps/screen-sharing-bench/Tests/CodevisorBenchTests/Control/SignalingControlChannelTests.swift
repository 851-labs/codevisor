import Darwin
import Foundation
import ScreenSharing
import Testing

@testable import CodevisorBench

@MainActor
struct SignalingControlChannelTests {
  @Test func controlMessagesCrossTheSignalingConnectionUntilThePeerShutsItDown() async throws {
    var descriptors: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    let viewerConnection = SignalingConnection(descriptor: descriptors[0], peerIPv4: "viewer")
    let viewer = SignalingControlChannel(viewerConnection)
    let host = SignalingControlChannel(SignalingConnection(descriptor: descriptors[1], peerIPv4: "host"))
    let (received, receiving) = AsyncStream.makeStream(of: ScreenSharingControlMessage.self)
    host.onMessage = { receiving.yield($0) }
    host.startReceiving()
    let request = UUID()

    viewer.send(.request(id: request))
    var messages = received.makeAsyncIterator()
    let first = await messages.next()
    viewerConnection.shutDown()
    await host.waitUntilClosed()

    #expect(first == .request(id: request))
    #expect(!host.isAvailable)
    #expect(!host.send(.heartbeat(lease: request)))
  }
}
