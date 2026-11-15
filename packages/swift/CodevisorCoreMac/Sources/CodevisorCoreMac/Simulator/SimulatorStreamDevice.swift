import CoreGraphics
import ScreenSharing

@MainActor
protocol SimulatorStreamDevice: AnyObject {
  var onChange: (() -> Void)? { get set }
  var state: ScreenSharingSimulatorState { get }
  var screenSize: CGSize? { get }
  func startCapturing() throws
  func show(to sink: any SimulatorFrameSink)
  func hide(from sink: any SimulatorFrameSink)
  func receive(_ message: ScreenSharingSimulatorMessage)
  func releaseTouches()
  func close()
}
