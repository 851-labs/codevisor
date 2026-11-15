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
  var isWaitingForTheSimulator: Bool { get }
  func setVisible(_ visible: Bool)
  func retry()
  func simulatorAppeared()
}

extension SimulatorConnection {
  public var isWaitingForTheSimulator: Bool { false }

  public func setVisible(_ visible: Bool) {}

  public func retry() {}

  public func simulatorAppeared() {}
}
