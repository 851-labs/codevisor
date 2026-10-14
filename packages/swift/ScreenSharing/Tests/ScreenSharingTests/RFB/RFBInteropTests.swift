import Foundation
import Testing
@testable import ScreenSharing

@Suite(.serialized)
struct RFBInteropTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["VNC_TEST_ROOT_COLOR"] != nil))
  func theDesktopArrivesExactlyAsTheServerConfiguredIt() async throws {
    let environment = ProcessInfo.processInfo.environment
    let geometry = try #require(environment["VNC_TEST_GEOMETRY"]).split(separator: "x").compactMap { Int($0) }
    let hex = try #require(environment["VNC_TEST_ROOT_COLOR"])
    let color = try #require(UInt32(hex, radix: 16))
    let (client, outcome) = try await VNCConnection.open(
      host: environment["VNC_TEST_HOST"]!, port: UInt16(environment["VNC_TEST_PORT"] ?? "5900")!,
      password: environment["VNC_TEST_PASSWORD"])
    defer { client.close() }
    #expect([outcome.parameters.width, outcome.parameters.height] == geometry)
    let (pixels, continuation) = AsyncStream<[UInt8]>.makeStream()
    let run = Task {
      try await client.run(
        onUpdate: { framebuffer, update in
          guard !update.rectangles.isEmpty else { return }
          let pixel = framebuffer.pixel(x: framebuffer.width / 4, y: framebuffer.height / 4)
          continuation.yield([pixel.red, pixel.green, pixel.blue])
        }, onEvent: { _ in })
    }
    defer { run.cancel() }
    var iterator = pixels.makeAsyncIterator()
    let centre = try #require(await iterator.next())
    #expect(centre == [UInt8(color >> 16 & 0xFF), UInt8(color >> 8 & 0xFF), UInt8(color & 0xFF)])
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["VNC_TEST_ROOT_COLOR"] != nil))
  func theShapeArrivesOnceThisClientMovesThePointer() async throws {
    let environment = ProcessInfo.processInfo.environment
    let (client, _) = try await VNCConnection.open(
      host: environment["VNC_TEST_HOST"]!, port: UInt16(environment["VNC_TEST_PORT"] ?? "5900")!,
      password: environment["VNC_TEST_PASSWORD"])
    defer { client.close() }
    let (cursors, continuation) = AsyncStream<RFBCursorShape>.makeStream()
    let run = Task {
      try await client.run(
        onUpdate: { _, update in if let cursor = update.cursor { continuation.yield(cursor) } }, onEvent: { _ in })
    }
    defer { run.cancel() }
    var iterator = cursors.makeAsyncIterator()
    let beforeMoving = try #require(await iterator.next())
    #expect(beforeMoving.isHidden, "Xvnc draws the pointer itself for a client that hasn't moved it.")
    try await client.send(.pointerEvent(buttons: 0, x: 100, y: 100))
    let shape = try #require(await iterator.next())
    print("interop: cursor \(shape.width)x\(shape.height) hotspot \(shape.hotspotX),\(shape.hotspotY)")
    #expect(!shape.isHidden)
    #expect(
      stride(from: 3, to: shape.pixels.count, by: 4).contains { shape.pixels[$0] == 255 }, "Some pixels are opaque.")
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["VNC_TEST_ROOT_COLOR"] != nil))
  func updatesArePushedAndFencesAnswered() async throws {
    let environment = ProcessInfo.processInfo.environment
    let (client, _) = try await VNCConnection.open(
      host: environment["VNC_TEST_HOST"]!, port: UInt16(environment["VNC_TEST_PORT"] ?? "5900")!,
      password: environment["VNC_TEST_PASSWORD"])
    defer { client.close() }
    enum Seen { case update(pushed: Bool), event(RFBServerEvent) }
    let (seen, continuation) = AsyncStream<Seen>.makeStream()
    let run = Task {
      try await client.run(
        onUpdate: { _, update in continuation.yield(.update(pushed: update.latency == nil)) },
        onEvent: { continuation.yield(.event($0)) })
    }
    defer { run.cancel() }
    var enabled = false, pushed = 0, roundTrip: Duration?
    for await item in seen {
      switch item {
      case .event(.continuousUpdates(true)): enabled = true
      case .event(.roundTrip(let rtt)): roundTrip = rtt
      case .update(let wasPushed): if wasPushed { pushed += 1 }
      default: break
      }
      if enabled, pushed >= 3, roundTrip != nil { break }
    }
    print("interop: continuous=\(enabled) pushed=\(pushed) roundTrip=\(String(describing: roundTrip))")
    #expect(enabled)
    #expect(pushed >= 3)
    #expect(roundTrip != nil)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["VNC_TEST_ROOT_COLOR"] != nil))
  func theDesktopResizesOnRequest() async throws {
    let environment = ProcessInfo.processInfo.environment
    let (client, outcome) = try await VNCConnection.open(
      host: environment["VNC_TEST_HOST"]!, port: UInt16(environment["VNC_TEST_PORT"] ?? "5900")!,
      password: environment["VNC_TEST_PASSWORD"])
    defer { client.close() }
    let original = (outcome.parameters.width, outcome.parameters.height)
    let (results, continuation) = AsyncStream<(RFBDesktopSizeResult, Int, Int)>.makeStream()
    let run = Task {
      try await client.run(
        onUpdate: { framebuffer, update in
          if let result = update.desktopSize { continuation.yield((result, framebuffer.width, framebuffer.height)) }
        }, onEvent: { _ in })
    }
    defer { run.cancel() }
    var iterator = results.makeAsyncIterator()
    let layout = try #require(await iterator.next(), "Xvnc announces its layout to a client that advertises -308")
    let screen = try #require(layout.0.screens.first)
    func resize(_ width: Int, _ height: Int) async throws -> (RFBDesktopSizeResult, Int, Int) {
      try await client.send(
        .setDesktopSize(
          width: width, height: height,
          screens: [RFBScreen(id: screen.id, x: 0, y: 0, width: width, height: height, flags: screen.flags)]))
      while let next = await iterator.next() {
        if next.0.reason == .thisClient { return next }
      }
      throw RFBError.connectionClosed
    }
    let resized = try await resize(800, 600)
    print("interop: resize → \(resized.0.status) \(resized.1)x\(resized.2)")
    #expect(resized.0.status == .ok)
    #expect((resized.1, resized.2) == (800, 600))
    let restored = try await resize(original.0, original.1)
    #expect(restored.0.status == .ok && (restored.1, restored.2) == original)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["VNC_TEST_ROOT_COLOR"] != nil))
  func utf8ClipboardTextRoundTrips() async throws {
    let environment = ProcessInfo.processInfo.environment
    let (client, _) = try await VNCConnection.open(
      host: environment["VNC_TEST_HOST"]!, port: UInt16(environment["VNC_TEST_PORT"] ?? "5900")!,
      password: environment["VNC_TEST_PASSWORD"])
    defer { client.close() }
    let sent = "héllo — 日本語 😀 \(UUID().uuidString.prefix(8))"
    let (messages, continuation) = AsyncStream<RFBExtendedClipboard.Message>.makeStream()
    let run = Task {
      try await client.run(
        onUpdate: { _, _ in },
        onEvent: { if case .extendedClipboard(let message) = $0 { continuation.yield(message) } })
    }
    defer { run.cancel() }
    let text = RFBExtendedClipboard.text
    var announced = false
    for await message in messages {
      switch message {
      case .caps(let formats, _, _):
        #expect(formats & text != 0, "TigerVNC offers UTF-8 text")
        try await client.send(
          .extendedClipboard(
            .caps(
              formats: text,
              actions: RFBExtendedClipboard.request | RFBExtendedClipboard.notify | RFBExtendedClipboard.provide,
              maximumSizes: [UInt32(RFBExtendedClipboard.maximumBytes)])))
        try await client.send(.extendedClipboard(.notify(formats: text)))
        announced = true
      case .request:
        try await client.send(.extendedClipboard(.provide(text: sent)))
      case .notify(let formats) where formats & text != 0:
        try await client.send(.extendedClipboard(.request(formats: text)))
      case .provide(let provided?) where provided.hasPrefix("echo:"):
        print("interop: clipboard round trip \(provided)")
        #expect(announced)
        #expect(provided == "echo:" + sent)
        return
      default: break
      }
    }
    Issue.record("the clipboard never came back")
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["VNC_TEST_ROOT_COLOR"] != nil))
  @MainActor
  func synthesizedTypingArrivesVerbatim() async throws {
    let typed = "Hello, wörld! \(UUID().uuidString.prefix(4))"
    let line = try await typeIntoSink { input in input.translate(.text(typed + "\n")) }
    #expect(line == "typed:" + typed)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["VNC_TEST_ROOT_COLOR"] != nil))
  @MainActor
  func commandActsAsControl() async throws {
    let kept = "kept \(UUID().uuidString.prefix(4))"
    let line = try await typeIntoSink(layout: { code, _ in code == 32 ? "u" : nil }) { input in
      input.translate(.text("discarded"))
        + input.translate(.key(code: 55, down: true, repeatKey: false, modifiers: 8))
        + input.translate(.key(code: 32, down: true, repeatKey: false, modifiers: 8))
        + input.translate(.key(code: 32, down: false, repeatKey: false, modifiers: 8))
        + input.translate(.key(code: 55, down: false, repeatKey: false, modifiers: 0))
        + input.translate(.text(kept + "\n"))
    }
    #expect(line == "typed:" + kept)
  }

  @MainActor
  private func typeIntoSink(
    layout: @escaping VNCKeyTranslator.Layout = VNCKeyTranslator.currentLayout,
    _ keys: (VNCInputTranslator) -> [RFBClientMessage]
  ) async throws -> String? {
    let environment = ProcessInfo.processInfo.environment
    let (client, outcome) = try await VNCConnection.open(
      host: environment["VNC_TEST_HOST"]!, port: UInt16(environment["VNC_TEST_PORT"] ?? "5900")!,
      password: environment["VNC_TEST_PASSWORD"])
    defer { client.close() }
    let (messages, continuation) = AsyncStream<RFBExtendedClipboard.Message>.makeStream()
    let run = Task {
      try await client.run(
        onUpdate: { _, _ in },
        onEvent: { if case .extendedClipboard(let message) = $0 { continuation.yield(message) } })
    }
    defer { run.cancel() }
    let input = VNCInputTranslator(
      width: outcome.parameters.width, height: outcome.parameters.height, keys: VNCKeyTranslator(layout: layout))
    let text = RFBExtendedClipboard.text
    for await message in messages {
      switch message {
      case .caps:
        try await client.send(
          .extendedClipboard(
            .caps(
              formats: text,
              actions: RFBExtendedClipboard.request | RFBExtendedClipboard.notify | RFBExtendedClipboard.provide,
              maximumSizes: [UInt32(RFBExtendedClipboard.maximumBytes)])))
        let pointer = ScreenSharingPointer(
          x: 60 / Double(outcome.parameters.width), y: 575 / Double(outcome.parameters.height))
        for message in input.translate(.move(pointer, modifiers: 0)) + keys(input) { try await client.send(message) }
      case .notify(let formats) where formats & text != 0:
        try await client.send(.extendedClipboard(.request(formats: text)))
      case .provide(let provided?) where provided.hasPrefix("typed:"):
        print("interop: \(provided)")
        return provided
      default: break
      }
    }
    Issue.record("the typed line never came back")
    return nil
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["VNC_TEST_ROOT_COLOR"] != nil))
  func tightJPEGStaysCloseToLossless() async throws {
    let region = RFBRectangle(x: 620, y: 320, width: 280, height: 160)
    func capture(quality: Int?) async throws -> (rgb: [UInt8], jpeg: Int) {
      let environment = ProcessInfo.processInfo.environment
      let (client, _) = try await VNCConnection.open(
        host: environment["VNC_TEST_HOST"]!, port: UInt16(environment["VNC_TEST_PORT"] ?? "5900")!,
        password: environment["VNC_TEST_PASSWORD"])
      defer { client.close() }
      try await client.setQualityLevel(quality)
      let (updates, continuation) = AsyncStream<([UInt8], Int)>.makeStream()
      let run = Task {
        try await client.run(
          onUpdate: { framebuffer, update in
            guard update.rectangles.contains(where: { $0.maxX > region.x && $0.maxY > region.y }) else { return }
            var rgb: [UInt8] = []
            for y in region.y..<region.maxY {
              for x in region.x..<region.maxX {
                let pixel = framebuffer.pixel(x: x, y: y)
                rgb += [pixel.red, pixel.green, pixel.blue]
              }
            }
            continuation.yield((rgb, update.jpegRectangles))
          }, onEvent: { _ in })
      }
      defer { run.cancel() }
      var iterator = updates.makeAsyncIterator()
      let (rgb, jpeg) = try #require(await iterator.next(), "an update covering the plasma window")
      return (rgb, jpeg)
    }
    let lossless = try await capture(quality: nil)
    let lossy = try await capture(quality: 8)
    var squaredError: Double = 0
    for (a, b) in zip(lossless.rgb, lossy.rgb) {
      let difference = Double(Int(a) - Int(b))
      squaredError += difference * difference
    }
    let mse: Double = squaredError / Double(lossless.rgb.count)
    let psnr: Double = mse == 0 ? Double.infinity : 10 * log10(255 * 255 / mse)
    var palette = Set<Int>()
    for index in stride(from: 0, to: lossless.rgb.count, by: 3) {
      let red = Int(lossless.rgb[index]), green = Int(lossless.rgb[index + 1]), blue = Int(lossless.rgb[index + 2])
      palette.insert(red << 16 | green << 8 | blue)
    }
    let colours = palette.count
    print(
      "interop: tight lossless jpeg=\(lossless.jpeg), quality 8 jpeg=\(lossy.jpeg), PSNR \(psnr) dB, \(colours) colours in the region"
    )
    #expect(lossless.jpeg == 0)
    #expect(lossy.jpeg > 0, "TigerVNC sent JPEG for photo-like content")
    #expect(psnr >= 30)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["VNC_TEST_HOST"] != nil))
  func connectsAndReceivesTheFirstUpdate() async throws {
    let environment = ProcessInfo.processInfo.environment
    let host = environment["VNC_TEST_HOST"]!
    let port = UInt16(environment["VNC_TEST_PORT"] ?? "5900")!
    let password = environment["VNC_TEST_PASSWORD"]
    let started = ContinuousClock.now
    let transport = try await RFBNetworkTransport.connect(host: host, port: port)
    let client = try RFBClient(transport: transport)
    let outcome = try await client.connect(password: password)
    print(
      "interop: handshake \(outcome.version) \(outcome.security) \(outcome.parameters) after \(ContinuousClock.now - started)"
    )
    let (updates, continuation) = AsyncStream<String>.makeStream()
    let run = Task {
      do {
        try await client.run(
          onUpdate: { framebuffer, update in
            continuation.yield(
              "update \(update.rectangles.count) rects resized=\(update.resized) size=\(framebuffer.width)x\(framebuffer.height) pixel(10,10)=\(framebuffer.pixel(x: 10, y: 10))"
            )
          },
          onEvent: { continuation.yield("event \($0)") })
      } catch {
        continuation.yield("ended: \(error)")
        continuation.finish()
        return error
      }
    }
    var received: [String] = []
    let deadline = Task {
      try await Task.sleep(for: .seconds(15))
      client.close()
    }
    for await line in updates {
      print("interop: \(line) at \(ContinuousClock.now - started)")
      received.append(line)
      if line.hasPrefix("update") || received.count >= 3 { break }
    }
    deadline.cancel()
    client.close()
    _ = await run.value
    #expect(received.contains { $0.hasPrefix("update") }, "no framebuffer update arrived: \(received)")
  }
}
