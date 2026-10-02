import CoreGraphics
import Foundation

public enum SimulatorConnectionPhase: Equatable, Sendable {
  case connecting
  /// The screen is showing.
  case streaming
  case reconnecting
  case failed(String)
}

/// What a simulator viewer shows: decoded video from a stream, or the latest snapshot.
public enum SimulatorScreenSource {
  case video(ScreenSharingFrameMailbox, ScreenSharingMetrics)
  case image(CGImage?)
}

/// A live view of one simulator: its screen, its state, and a way to send it input. The macOS
/// app streams it over WebRTC; a client without WebRTC polls snapshots.
@MainActor
public protocol SimulatorConnection: AnyObject {
  var phase: SimulatorConnectionPhase { get }
  var state: ScreenSharingSimulatorState? { get }
  var source: SimulatorScreenSource? { get }
  func start()
  func stop()
  @discardableResult func send(_ message: ScreenSharingSimulatorMessage) -> Bool
  /// Called by the screen as frames reach it.
  func presented(frameSize: CGSize)
}
