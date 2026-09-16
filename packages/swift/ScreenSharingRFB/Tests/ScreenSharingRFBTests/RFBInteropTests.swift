import Foundation
import Testing
@testable import ScreenSharingRFB

/// Runs only against a real server named by the environment, e.g. the tunnel
/// to the interop test box (`VNC_TEST_HOST=127.0.0.1 VNC_TEST_PORT=5901
/// VNC_TEST_PASSWORD=codevisor`). Reports the handshake, the first update and
/// the timing, so a stall can be placed.
struct RFBInteropTests {
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
      if received.count >= 3 { break }
    }
    deadline.cancel()
    client.close()
    _ = await run.value
    #expect(received.contains { $0.hasPrefix("update") }, "no framebuffer update arrived: \(received)")
  }
}
