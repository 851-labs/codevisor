import CodevisorTestSupport
import Foundation
import Synchronization
import Testing

@testable import ScreenSharing
@testable import ScreenSharingV2

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingV2SessionTests {
  private final class Encoders: Sendable {
    let built = TestSignal()
    private let encoders = Mutex<[RecordingTileEncoder]>([])

    var all: [RecordingTileEncoder] { encoders.withLock { $0 } }

    func make(_ configuration: ScreenSharingVideoConfiguration) -> RecordingTileEncoder {
      let encoder = RecordingTileEncoder(
        layout: ScreenSharingV2TileLayout(width: configuration.width, height: configuration.height, count: 1))
      encoders.withLock { $0.append(encoder) }
      built.signal()
      return encoder
    }
  }

  private func link(_ encoders: Encoders = Encoders()) throws -> ScreenSharingV2HostLink {
    let configuration = try ScreenSharingV2Profile.captureConfiguration(width: 640, height: 360)
    return ScreenSharingV2HostLink(configuration: configuration, metrics: ScreenSharingMetrics()) { configuration, _ in
      encoders.make(configuration)
    }
  }

  @Test func aViewerWithTheSessionTokenSendsControlAndReceivesCursorDatagrams() async throws {
    let pair = try await IrohConnectionPair.connect()
    defer { pair.close() }
    let host = try link()
    let session = ScreenSharingV2ViewingSession(connection: pair.viewer)
    defer {
      session.close()
      host.close()
    }
    var control: [ScreenSharingControlMessage] = []
    let controlArrived = TestSignal()
    host.linkChannels.control.onMessage = {
      control.append($0)
      controlArrived.signal()
    }
    let subscribed = TestSignal()
    host.linkChannels.cursor.onMessage = { if case .subscribe = $0 { subscribed.signal() } }

    async let viewer: Void = session.start(token: "session-token")
    try await host.accept(pair.host) { $0 == "session-token" ? nil : "wrong token" }
    try await viewer

    let request = UUID()
    #expect(session.control?.send(.request(id: request)) == true)
    await controlArrived.cancellableWait()
    #expect(control == [.request(id: request)])

    var cursor: [ScreenSharingCursorUpdate] = []
    let moved = TestSignal()
    session.onCursorChanged = {
      cursor.append($0)
      moved.signal()
    }
    await subscribed.cancellableWait()
    #expect(host.linkChannels.cursor.send(.position(ScreenSharingPointer(x: 0.25, y: 0.5))))
    await moved.cancellableWait()
    #expect(cursor == [.normalizedPosition(ScreenSharingPointer(x: 0.25, y: 0.5))])
  }

  @Test func theHostRefusesAViewerWithoutTheSessionTokenAndTheViewerSeesWhy() async throws {
    let pair = try await IrohConnectionPair.connect()
    defer { pair.close() }
    let host = try link()
    let session = ScreenSharingV2ViewingSession(connection: pair.viewer)
    defer {
      session.close()
      host.close()
    }

    let viewer = Task { try await session.start(token: "stale-token") }
    await #expect(throws: ScreenSharingError.self) {
      try await host.accept(pair.host) { _ in "This screen-sharing session ended." }
    }
    let error = await #expect(throws: ScreenSharingError.self) { try await viewer.value }
    #expect(error?.localizedDescription == "This screen-sharing session ended.")
    #expect(host.linkChannels.control.isAvailable == false)
  }

  @Test func aNewCaptureSizeRebuildsTheEncoderOnTheSameConnectionAndDropsOldSizedFrames() async throws {
    let pair = try await IrohConnectionPair.connect()
    defer { pair.close() }
    let encoders = Encoders()
    let host = try link(encoders)
    let session = ScreenSharingV2ViewingSession(connection: pair.viewer)
    defer {
      session.close()
      host.close()
    }
    async let viewer: Void = session.start(token: "t")
    try await host.accept(pair.host) { _ in nil }
    try await viewer
    let first = try #require(encoders.all.first)
    host.frameRouter.push(try TestPixels.frame(shade: 10, timestampNs: 1_000))
    await first.encodes.cancellableWait()

    let larger = try ScreenSharingV2Profile.captureConfiguration(width: 1280, height: 720)
    host.updateVideoConfiguration(larger)
    await encoders.built.cancellableWait(for: 2)
    let second = try #require(encoders.all.last)
    await second.attached.cancellableWait()
    host.frameRouter.push(try TestPixels.frame(shade: 20, timestampNs: 2_000))
    host.frameRouter.push(try TestPixels.frame(width: 1280, height: 720, shade: 30, timestampNs: 3_000))
    await second.encodes.cancellableWait()

    #expect(first.requests.count == 1)
    #expect(second.requests.map(\.sourceTimestampNs) == [3_000])
  }

  @Test func backToBackResizesEndWithAnEngineForTheLastSize() async throws {
    let pair = try await IrohConnectionPair.connect()
    defer { pair.close() }
    let encoders = Encoders()
    let host = try link(encoders)
    let session = ScreenSharingV2ViewingSession(connection: pair.viewer)
    defer {
      session.close()
      host.close()
    }
    async let viewer: Void = session.start(token: "t")
    try await host.accept(pair.host) { _ in nil }
    try await viewer

    host.updateVideoConfiguration(try ScreenSharingV2Profile.captureConfiguration(width: 1280, height: 720))
    host.updateVideoConfiguration(try ScreenSharingV2Profile.captureConfiguration(width: 1920, height: 1080))
    await encoders.built.cancellableWait(for: 3)
    let last = try #require(encoders.all.last)
    await last.attached.cancellableWait()
    #expect(last.layout.width == 1920)
    host.frameRouter.push(try TestPixels.frame(width: 1920, height: 1080, shade: 40, timestampNs: 4_000))
    await last.encodes.cancellableWait()
    #expect(last.requests.map(\.sourceTimestampNs) == [4_000])
  }
}
