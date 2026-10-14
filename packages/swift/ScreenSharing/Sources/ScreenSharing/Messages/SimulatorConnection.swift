import CoreGraphics
import Foundation

public enum SimulatorConnectionPhase: Equatable, Sendable {
  case connecting
  case streaming
  case reconnecting
  case failed(String)
}

public enum SimulatorScreenSource {
  case video(ScreenSharingFrameMailbox, ScreenSharingMetrics)
  case image(CGImage?)
}

@MainActor
public protocol SimulatorConnection: AnyObject {
  var phase: SimulatorConnectionPhase { get }
  var state: ScreenSharingSimulatorState? { get }
  var source: SimulatorScreenSource? { get }
  var frameSize: CGSize? { get }
  func start()
  func stop()
  @discardableResult func send(_ message: ScreenSharingSimulatorMessage) -> Bool
  func presented(frameSize: CGSize)
}
