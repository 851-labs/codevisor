import CodevisorTestSupport
import Foundation
import Testing
import ScreenSharingTesting
@testable import ScreenSharing

/// Tight (encoding 7), 851-2313: every rectangle type decoded to exact
/// pixels (JPEG within a PSNR bound), and every scene through the reference
/// server's encoder.
struct RFBTightTests {
  typealias Harness = RFBClientLoopbackTests.Harness

  /// Decodes one Tight rectangle body into a fresh framebuffer.
  static func decode(
    _ body: [UInt8], _ rect: RFBRectangle, decoder: RFBTightDecoder = RFBTightDecoder()
  ) async throws
    -> RFBFramebuffer
  {
    let framebuffer = try RFBFramebuffer(width: rect.maxX, height: rect.maxY)
    try await decoder.decode(
      rect, from: RFBInputStream(transport: ScriptedTransport(body, chunk: 7)), into: framebuffer)
    return framebuffer
  }

  static func rgb(_ framebuffer: RFBFramebuffer, _ rect: RFBRectangle) -> [UInt8] {
    var out: [UInt8] = []
    for y in rect.y..<rect.maxY {
      for x in rect.x..<rect.maxX {
        let pixel = framebuffer.pixel(x: x, y: y)
        out += [pixel.red, pixel.green, pixel.blue]
      }
    }
    return out
  }

  static func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
    // A plain loop: the chained closures were slow to type-check (CI).
    var squaredError: Double = 0
    for (x, y) in zip(a, b) {
      let difference = Double(Int(x) - Int(y))
      squaredError += difference * difference
    }
    let mse: Double = squaredError / Double(a.count)
    return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
  }

  // MARK: L1

  @Test(arguments: [
    (0, [UInt8(0)]), (127, [0x7F]), (128, [0x80, 0x01]), (16383, [0xFF, 0x7F]), (16384, [0x80, 0x80, 0x01]),
  ])
  func compactLengthsRoundTrip(_ length: Int, _ bytes: [UInt8]) async throws {
    #expect(RFBTightEncoder.compactLength(length) == bytes)
    #expect(
      try await RFBTightDecoder.compactLength(from: RFBInputStream(transport: ScriptedTransport(bytes))) == length)
  }

  @Test func fillPaintsOneColourGivenAsRGB() async throws {
    let rect = RFBRectangle(x: 1, y: 1, width: 3, height: 2)
    let framebuffer = try await Self.decode([0x80, 10, 20, 30], rect)
    #expect(Self.rgb(framebuffer, rect) == Array(repeating: [UInt8(10), 20, 30], count: 6).flatMap { $0 })
  }

  @Test func aTwoColourPaletteIsOneBitPerPixelRowsPaddedToBytes() async throws {
    // 3 × 2, stream 1, explicit palette filter, colours black/white, rows 101 and 010 (under 12 bytes: raw).
    let rect = RFBRectangle(x: 0, y: 0, width: 3, height: 2)
    let body: [UInt8] = [0x50, 1, 1, 0, 0, 0, 255, 255, 255, 0b1010_0000, 0b0100_0000]
    let rgb = Self.rgb(try await Self.decode(body, rect), rect)
    #expect(rgb == [255, 255, 255, 0, 0, 0, 255, 255, 255, 0, 0, 0, 255, 255, 255, 0, 0, 0])
  }

  @Test func anIndexedPaletteRejectsIndicesOutsideIt() async throws {
    let rect = RFBRectangle(x: 0, y: 0, width: 2, height: 1)
    let good: [UInt8] = [0x60, 1, 2, 1, 1, 1, 2, 2, 2, 3, 3, 3, 2, 0]
    #expect(Self.rgb(try await Self.decode(good, rect), rect) == [3, 3, 3, 1, 1, 1])
    await #expect(throws: RFBError.self) {
      _ = try await Self.decode([0x60, 1, 2, 1, 1, 1, 2, 2, 2, 3, 3, 3, 5, 0], rect)
    }
  }

  @Test func theGradientFilterUndoesItsPrediction() async throws {
    // An image, its gradient residuals computed independently here, then decoded back.
    let width = 5, height = 4
    let image = (0..<width * height * 3).map { UInt8(truncatingIfNeeded: $0 * 37 &+ ($0 / 7) * 11) }
    var residuals = [UInt8](repeating: 0, count: image.count)
    for y in 0..<height {
      for x in 0..<width {
        for c in 0..<3 {
          let i = (y * width + x) * 3 + c
          let above = y > 0 ? Int(image[i - width * 3]) : 0
          let prediction =
            x == 0
            ? above
            : min(max(Int(image[i - 3]) + above - (y > 0 ? Int(image[i - width * 3 - 3]) : 0), 0), 255)
          residuals[i] = UInt8(truncatingIfNeeded: Int(image[i]) - prediction)
        }
      }
    }
    #expect(RFBTightDecoder.ungradient(residuals, width: width, height: height) == image)
  }

  @Test func copyFilterDataOverZlibAndStreamResets() async throws {
    let rect = RFBRectangle(x: 0, y: 0, width: 8, height: 8)
    let source = try RFBFramebuffer(width: 8, height: 8)
    var pixels: [UInt8] = []
    for index in 0..<64 {
      pixels += [UInt8(index * 3), UInt8(index), UInt8(255 - index), 255]
    }
    try source.fillRaw(rect, from: pixels)
    let encoder = RFBTightEncoder()
    let first = try encoder.encode(rect, from: source, qualityLevel: nil)
    #expect(first.first == 0x00, "More than 16 colours and no quality level: copy filter, stream 0")
    let decoder = RFBTightDecoder()
    let decoded = try await Self.decode(first, rect, decoder: decoder)
    #expect(Self.rgb(decoded, rect) == Self.rgb(source, rect))
    // The stream continues across rectangles; a reset bit starts it over.
    let second = try encoder.encode(rect, from: source, qualityLevel: nil)
    #expect(Self.rgb(try await Self.decode(second, rect, decoder: decoder), rect) == Self.rgb(source, rect))
    await #expect(throws: RFBError.self) {
      // Resetting stream 0 while the encoder continues it: the continued data no longer inflates.
      _ = try await Self.decode(
        [0x01] + Array(try encoder.encode(rect, from: source, qualityLevel: nil).dropFirst()), rect, decoder: decoder)
    }
  }

  @Test func jpegRectanglesDecodeWithinTheQualityBound() async throws {
    let rect = RFBRectangle(x: 0, y: 0, width: 64, height: 48)
    let source = try RFBFramebuffer(width: 64, height: 48)
    var scene = RFBLoopbackScene(kind: .photo, seed: 3)
    _ = try scene.next(on: source)
    let body = try RFBTightEncoder().encode(rect, from: source, qualityLevel: 8)
    #expect(body.first == 0x90)
    let psnr = Self.psnr(Self.rgb(try await Self.decode(body, rect), rect), Self.rgb(source, rect))
    #expect(psnr >= 35, "PSNR \(psnr) dB")
  }

  @Test func unknownFiltersAndPNGAreRejected() async throws {
    let rect = RFBRectangle(x: 0, y: 0, width: 2, height: 2)
    await #expect(throws: RFBError.self) { _ = try await Self.decode([0x40, 9], rect) }
    await #expect(throws: RFBError.self) { _ = try await Self.decode([0xA0, 0], rect) }
  }

  // MARK: L2 — through the reference server

  @Test(arguments: RFBLoopbackScene.Kind.allCases.filter { $0 != .idle })
  func everySceneConvergesOverLosslessTight(kind: RFBLoopbackScene.Kind) async throws {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.width = 96
    configuration.height = 64
    configuration.negotiateEncoding = true
    let harness = try await Harness(configuration: configuration)
    defer { harness.stop() }
    _ = try #require(await harness.nextUpdate())
    var scene = RFBLoopbackScene(kind: kind, seed: 11)
    for frame in 0..<6 {
      #expect(try harness.server.play(&scene))
      let snapshot = try #require(await harness.nextUpdate())
      let full = RFBRectangle(x: 0, y: 0, width: snapshot.width, height: snapshot.height)
      let client = try RFBFramebuffer(width: snapshot.width, height: snapshot.height)
      try client.fillRaw(full, from: snapshot.pixels)
      #expect(Self.rgb(client, full) == Self.rgb(harness.server.framebuffer, full), "frame \(frame) of \(kind)")
    }
  }

  @Test func theClientsQualityLevelTurnsJPEGOn() async throws {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.width = 96
    configuration.height = 64
    configuration.negotiateEncoding = true
    let server = try await RFBLoopbackServer(configuration: configuration)
    defer { server.stop() }
    let client = try RFBClient(
      transport: try await RFBNetworkTransport.connect(host: "127.0.0.1", port: server.port), qualityLevel: 8)
    _ = try await client.connect(password: "secret")
    #expect(await awaitPolled { server.advertisedEncodings.contains(-24) })
    let (updates, continuation) = AsyncStream<[UInt8]>.makeStream()
    let run = Task { try await client.run(onUpdate: { fb, _ in continuation.yield(fb.pixels) }, onEvent: { _ in }) }
    defer {
      run.cancel()
      client.close()
    }
    var iterator = updates.makeAsyncIterator()
    _ = await iterator.next()
    var scene = RFBLoopbackScene(kind: .photo, seed: 5)
    #expect(try server.play(&scene))
    let pixels = try #require(await iterator.next())
    let full = RFBRectangle(x: 0, y: 0, width: 96, height: 64)
    let decoded = try RFBFramebuffer(width: 96, height: 64)
    try decoded.fillRaw(full, from: pixels)
    #expect(Self.psnr(Self.rgb(decoded, full), Self.rgb(server.framebuffer, full)) >= 35)
    #expect(Self.rgb(decoded, full) != Self.rgb(server.framebuffer, full), "lossy: it went through JPEG")
    // Turning JPEG off mid-session: the next photo frame is exact again.
    try await client.setQualityLevel(nil)
    #expect(await awaitPolled { !server.advertisedEncodings.contains(-24) })
    #expect(try server.play(&scene))
    let exact = try #require(await iterator.next())
    try decoded.fillRaw(full, from: exact)
    #expect(Self.rgb(decoded, full) == Self.rgb(server.framebuffer, full))
  }
}

extension RFBTightTests {
  /// A reconnect starts the server's Tight zlib streams over with the new client's (found by the tophat).
  @Test func aSecondConnectionDecodesAfterTheFirstUsedTheZlibStreams() async throws {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.width = 96
    configuration.height = 64
    configuration.negotiateEncoding = true
    let server = try await RFBLoopbackServer(configuration: configuration)
    defer { server.stop() }
    var scene = RFBLoopbackScene(kind: .photo, seed: 2)
    for _ in 0..<2 {
      let client = try RFBClient(transport: try await RFBNetworkTransport.connect(host: "127.0.0.1", port: server.port))
      _ = try await client.connect(password: "secret")
      let (updates, continuation) = AsyncStream<Void>.makeStream()
      let run = Task { try await client.run(onUpdate: { _, _ in continuation.yield() }, onEvent: { _ in }) }
      var iterator = updates.makeAsyncIterator()
      _ = await iterator.next()
      #expect(try server.play(&scene))
      #expect(await iterator.next() != nil, "the zlib-compressed frame decoded")
      run.cancel()
      client.close()
      _ = await run.result
    }
  }
}
