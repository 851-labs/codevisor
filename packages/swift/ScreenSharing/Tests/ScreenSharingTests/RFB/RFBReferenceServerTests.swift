import CodevisorTestSupport
import Foundation
import Testing
import ScreenSharingTesting
@testable import ScreenSharing

struct RFBReferenceServerTests {
  typealias Harness = RFBClientLoopbackTests.Harness

  @Test func implementsEveryEncodingTheClientAdvertises() {
    let missing = RFBEncoding.supported.filter { !RFBLoopbackServer.implementedEncodings.contains($0) }
    #expect(missing.isEmpty, "The reference server lacks \(missing); add its side with the client's.")
  }

  @Test(arguments: RFBLoopbackScene.Kind.allCases)
  func aSceneIsAFunctionOfItsSeed(kind: RFBLoopbackScene.Kind) throws {
    func play(seed: UInt64) throws -> (pixels: [UInt8], rectangles: [String]) {
      let framebuffer = try RFBFramebuffer(width: 96, height: 64)
      var scene = RFBLoopbackScene(kind: kind, seed: seed)
      var rectangles: [String] = []
      for _ in 0..<12 { rectangles += try scene.next(on: framebuffer).map { "\($0)" } }
      return (framebuffer.pixels, rectangles)
    }
    let first = try play(seed: 7), again = try play(seed: 7)
    #expect(first.pixels == again.pixels)
    #expect(first.rectangles == again.rectangles)
    if kind != .idle {
      #expect(try play(seed: 8).pixels != first.pixels, "A different seed should change the content.")
    }
  }

  @Test func idleProducesNoUpdates() throws {
    let framebuffer = try RFBFramebuffer(width: 32, height: 32)
    var scene = RFBLoopbackScene(kind: .idle, seed: 1)
    for _ in 0..<5 { #expect(try scene.next(on: framebuffer).isEmpty) }
  }

  @Test(arguments: RFBLoopbackScene.Kind.allCases.filter { $0 != .idle })
  func theClientConvergesOnEveryScene(kind: RFBLoopbackScene.Kind) async throws {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.width = 96
    configuration.height = 64
    configuration.encoding = .zrle
    let harness = try await Harness(configuration: configuration)
    defer { harness.stop() }
    _ = try #require(await harness.nextUpdate())
    var scene = RFBLoopbackScene(kind: kind, seed: 42)
    for frame in 0..<8 {
      #expect(try harness.server.play(&scene))
      let snapshot = try #require(await harness.nextUpdate(), "frame \(frame)")
      #expect(snapshot.width == harness.server.framebuffer.width, "frame \(frame)")
      #expect(snapshot.height == harness.server.framebuffer.height, "frame \(frame)")
      #expect(colour(snapshot.pixels) == colour(harness.server.framebuffer.pixels), "frame \(frame) of \(kind)")
    }
  }

  @Test func aFrameWaitsForThePreviousOneToBeSent() async throws {
    let server = try await RFBLoopbackServer()
    defer { server.stop() }
    var scene = RFBLoopbackScene(kind: .scroll, seed: 3)
    #expect(try server.play(&scene))
    let afterFirst = server.framebuffer.pixels
    #expect(try server.play(&scene) == false)
    #expect(scene.frame == 1, "The refused frame did not advance the scene.")
    #expect(server.framebuffer.pixels == afterFirst, "The refused frame did not touch the framebuffer.")
  }

  private func colour(_ pixels: [UInt8]) -> [UInt8] {
    pixels.enumerated().compactMap { $0.offset % 4 == 3 ? nil : $0.element }
  }

  @Test func echoMarkersEncodeTheirSequence() {
    for sequence in [1, 2, 255, 256, 65535] {
      let marker = RFBLoopbackServer.echoMarker(sequence: sequence)
      #expect(
        RFBLoopbackServer.echoSequence(blue: marker.blue, green: marker.green, red: marker.red) == sequence)
    }
    #expect(RFBLoopbackServer.echoSequence(blue: 1, green: 0, red: 0) == nil, "Only the tagged red channel marks.")
  }

  @Test func pointerInputIsEchoedAsAMarkerAtThePointer() async throws {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.echoPointer = true
    let harness = try await Harness(configuration: configuration)
    defer { harness.stop() }
    _ = try #require(await harness.nextUpdate())
    try await harness.client.send(.pointerEvent(buttons: 0, x: 10, y: 20))
    let first = try #require(await harness.nextUpdate())
    let pixel = first.pixel(x: 10, y: 20)
    #expect(RFBLoopbackServer.echoSequence(blue: pixel[0], green: pixel[1], red: pixel[2]) == 1)
    try await harness.client.send(.pointerEvent(buttons: 1, x: 62, y: 46))
    let second = try #require(await harness.nextUpdate())
    let corner = second.pixel(x: 62, y: 46)
    #expect(RFBLoopbackServer.echoSequence(blue: corner[0], green: corner[1], red: corner[2]) == 2)
  }

  @Test func withoutEchoPointerInputChangesNothing() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    _ = try #require(await harness.nextUpdate())
    #expect(await awaitPolled { harness.server.isRequestPending })
    try await harness.client.send(.pointerEvent(buttons: 0, x: 10, y: 20))
    #expect(await awaitPolled { harness.server.received.contains(.pointerEvent(buttons: 0, x: 10, y: 20)) })
    #expect(harness.server.isRequestPending, "No update was sent in reply to the pointer.")
  }
}
