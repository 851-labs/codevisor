import ScreenSharing
import ScreenSharingBench

protocol LoopbackSource: Sendable {
  var produced: [BenchVersionEvent] { get async }

  func run(for duration: Duration) async throws
  func adapt(to configuration: ScreenSharingVideoConfiguration) async throws
}
