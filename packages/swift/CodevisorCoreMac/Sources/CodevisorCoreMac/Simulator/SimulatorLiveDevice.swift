import CoreGraphics
import Foundation
import ScreenSharing

@MainActor
final class SimulatorLiveDevice: SimulatorStreamDevice {
  var onChange: (() -> Void)?

  private let control: SimulatorDeviceControl
  private var capture: SimulatorScreenCapture?
  private var displayName: String?
  private var sinks: [any SimulatorFrameSink] = []

  init(udid: String) throws {
    control = try SimulatorDeviceControl(udid: udid)
    control.onChange = { [weak self] in self?.changed() }
  }

  var state: ScreenSharingSimulatorState { control.state }

  var screenSize: CGSize? { capture?.size }

  func startCapturing() throws {
    guard capture == nil else { return }

    let wanted = control.displayName
    let screens = try SimulatorRuntime.screens(SimulatorRuntime.device(udid: control.udid))
    let screen = screens.first { $0.name == wanted } ?? screens.first { $0.type == 0 } ?? screens.first
    guard let screen else { throw SimulatorRuntime.Failure("The simulator has no screen to show.") }

    let capture = SimulatorScreenCapture(screen: screen)
    self.capture = capture
    displayName = screen.name
    for sink in sinks { capture.add(sink) }
    capture.start()
  }

  func show(to sink: any SimulatorFrameSink) {
    sinks.append(sink)
    capture?.add(sink)
  }

  func hide(from sink: any SimulatorFrameSink) {
    sinks.removeAll { $0 === sink }
    capture?.remove(sink)
  }

  func receive(_ message: ScreenSharingSimulatorMessage) {
    switch message {
    case .touch(let phase, let touches): touch(phase, touches)
    case .button(let name, let down): control.button(name, down: down)
    case .key(let usage, let down): control.key(usage, down: down)
    case .rotate(let orientation): control.rotate(to: orientation)
    case .posture(let posture): control.setPosture(posture)
    case .crown, .state: break
    }
  }

  func releaseTouches() {
    control.releaseTouches()
  }

  func close() {
    capture?.stop()
    control.close()
  }

  nonisolated static func framebufferPoint(x: Double, y: Double, turns: Int) -> CGPoint {
    let x = min(1, max(0, x)), y = min(1, max(0, y))
    switch ((turns % 4) + 4) % 4 {
    case 1: return CGPoint(x: y, y: 1 - x)
    case 2: return CGPoint(x: 1 - x, y: 1 - y)
    case 3: return CGPoint(x: 1 - y, y: x)
    default: return CGPoint(x: x, y: y)
    }
  }

  nonisolated static func edgeCode(_ edge: ScreenSharingSimulatorEdge?, turns: Int) -> UInt64 {
    guard let edge else { return 0 }

    let order: [ScreenSharingSimulatorEdge] = [.top, .right, .bottom, .left]
    guard let index = order.firstIndex(of: edge) else { return 0 }

    let native = order[(((index - turns) % 4) + 4) % 4]
    switch native {
    case .top: return 1
    case .left: return 2
    case .bottom: return 3
    case .right: return 4
    }
  }

  private var turns: Int {
    let held = control.canRotate ? control.orientation.quarterTurns : 0
    return held + control.screenTurns
  }

  private func touch(_ phase: ScreenSharingSimulatorTouchPhase, _ touches: [ScreenSharingSimulatorTouch]) {
    let turns = turns
    control.touch(
      phase,
      touches.prefix(5).map { touch in
        (
          touch.id, Self.framebufferPoint(x: touch.x, y: touch.y, turns: turns),
          Self.edgeCode(touch.edge, turns: turns)
        )
      })
  }

  private func changed() {
    if control.displayName != displayName, let old = capture {
      old.stop()
      capture = nil
      try? startCapturing()
    }
    onChange?()
  }
}
