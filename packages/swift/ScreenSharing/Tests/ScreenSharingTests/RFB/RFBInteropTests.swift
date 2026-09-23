import Foundation
import Testing
@testable import ScreenSharing

/// Runs only against a real server named by the environment: `bun run
/// vnc:interop` (a pinned TigerVNC container, docs/plans/vnc-validation.md
/// layer L3) or a tunnel to a test box (`VNC_TEST_HOST=127.0.0.1
/// VNC_TEST_PORT=5901 VNC_TEST_PASSWORD=codevisor`). Reports the handshake,
/// the first update and the timing, so a stall can be placed.
struct RFBInteropTests {
  /// The container's known desktop: `VNC_TEST_GEOMETRY` (WxH) and a solid
  /// `VNC_TEST_ROOT_COLOR` (RRGGBB) arrive exactly as configured.
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
        onUpdate: { framebuffer, _ in
          let pixel = framebuffer.pixel(x: framebuffer.width / 2, y: framebuffer.height / 2)
          continuation.yield([pixel.red, pixel.green, pixel.blue])
        }, onEvent: { _ in })
    }
    defer { run.cancel() }
    var iterator = pixels.makeAsyncIterator()
    let centre = try #require(await iterator.next())
    #expect(centre == [UInt8(color >> 16 & 0xFF), UInt8(color >> 8 & 0xFF), UInt8(color & 0xFF)])
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
      // One update proves the path; a static desktop sends no more, so don't wait for them.
      if line.hasPrefix("update") || received.count >= 3 { break }
    }
    deadline.cancel()
    client.close()
    _ = await run.value
    #expect(received.contains { $0.hasPrefix("update") }, "no framebuffer update arrived: \(received)")
  }
}
