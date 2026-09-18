import ScreenSharing
import CodevisorTestSupport
import CoreVideo
import Foundation
import Testing
@testable import ScreenSharing

/// The viewing session against a real server named by the environment
/// (`VNC_TEST_HOST`, `VNC_TEST_PORT`, `VNC_TEST_PASSWORD`); skipped otherwise.
@MainActor
struct VNCSessionInteropTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["VNC_TEST_HOST"] != nil))
  func framesReachTheMailbox() async throws {
    let environment = ProcessInfo.processInfo.environment
    let (client, outcome) = try await VNCConnection.open(
      host: environment["VNC_TEST_HOST"]!, port: UInt16(environment["VNC_TEST_PORT"] ?? "5900")!,
      password: environment["VNC_TEST_PASSWORD"])
    let session = VNCScreenSharingSession(client: client, parameters: outcome.parameters)
    var transports: [String] = []
    session.onConnectionChanged = { transports.append($0) }
    let arrived = await awaitPolled(timeout: .seconds(20)) { session.frames.isHolding }
    let snapshot = session.metrics.snapshot()
    print(
      "interop: arrived=\(arrived) counters=\(snapshot.counters) labels=\(snapshot.labels) failure=\(String(describing: session.failure)) transports=\(transports)"
    )
    if let frame = session.frames.take() {
      print(
        "interop: frame \(CVPixelBufferGetWidth(frame.pixelBuffer))x\(CVPixelBufferGetHeight(frame.pixelBuffer)) format=\(CVPixelBufferGetPixelFormatType(frame.pixelBuffer))"
      )
    }
    session.close()
    #expect(arrived)
  }
}
