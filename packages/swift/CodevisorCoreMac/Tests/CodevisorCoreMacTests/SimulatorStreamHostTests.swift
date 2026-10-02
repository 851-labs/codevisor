import CoreGraphics
import Foundation
import ScreenSharing
import Testing

@testable import CodevisorCoreMac

@Suite("Simulator stream host")
struct SimulatorStreamHostTests {
  @Test("Accepts only simulator targets naming a device")
  func targets() {
    let udid = "8C2D33A1-7E5B-4F0A-9C3D-2B1E4F6A7D90"
    #expect(SimulatorStreamTarget.udid(from: "simulator:\(udid)") == udid)
    #expect(SimulatorStreamTarget.udid(from: "simulator:\(udid.lowercased())") == udid)
    #expect(SimulatorStreamTarget.udid(from: "simulator:../../etc") == nil)
    #expect(SimulatorStreamTarget.udid(from: udid) == nil)
  }

  /// The host turns the framebuffer clockwise by `turns` before encoding; this is that forward
  /// map, for checking the inverse the host applies to touches.
  static func turned(_ point: CGPoint, turns: Int) -> CGPoint {
    var point = point
    for _ in 0..<turns { point = CGPoint(x: 1 - point.y, y: point.x) }
    return point
  }

  @Test("A touch on the upright video lands where that pixel is in the framebuffer", arguments: 0..<4)
  func touchesFollowTheTurn(turns: Int) {
    for native in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.05), CGPoint(x: 0.5, y: 0.5)] {
      let video = Self.turned(native, turns: turns)
      let back = SimulatorStreamHost.framebufferPoint(x: video.x, y: video.y, turns: turns)
      #expect(abs(back.x - native.x) < 1e-9 && abs(back.y - native.y) < 1e-9)
    }
  }

  @Test("System edge gestures name the framebuffer's edge, whatever way the device is held")
  func edges() {
    // Upright: the guest's 1 top, 2 left, 3 bottom, 4 right.
    #expect(SimulatorStreamHost.edgeCode(.top, turns: 0) == 1)
    #expect(SimulatorStreamHost.edgeCode(.left, turns: 0) == 2)
    #expect(SimulatorStreamHost.edgeCode(.bottom, turns: 0) == 3)
    #expect(SimulatorStreamHost.edgeCode(.right, turns: 0) == 4)
    // Turned clockwise, the framebuffer's bottom (Home indicator) shows on the left.
    #expect(SimulatorStreamHost.edgeCode(.left, turns: 1) == 3)
    #expect(SimulatorStreamHost.edgeCode(.top, turns: 2) == 3)
    #expect(SimulatorStreamHost.edgeCode(.right, turns: 3) == 3)
    #expect(SimulatorStreamHost.edgeCode(nil, turns: 1) == 0)
  }

  @Test("Frames fit the encoder: turned, scaled into 3840×2160, even sides")
  func outputSizes() {
    // A tall iPhone framebuffer is taller than the encoder allows.
    #expect(SimulatorScreenCapture.outputSize(width: 1260, height: 2736, turns: 0) == CGSize(width: 994, height: 2160))
    // Held landscape, the same screen fits at full size.
    #expect(SimulatorScreenCapture.outputSize(width: 1260, height: 2736, turns: 1) == CGSize(width: 2736, height: 1260))
    #expect(SimulatorScreenCapture.outputSize(width: 422, height: 514, turns: 0) == CGSize(width: 422, height: 514))
  }

  @Test("Orientation codes match what each guest path expects")
  func orientationCodes() {
    // CoreMotion (Device Hub's rotate) takes locationd's names, not UIKit's.
    #expect(
      ScreenSharingSimulatorOrientation.allCases.map(SimulatorDeviceControl.motionName) == [
        "portrait", "landscape-left", "pud", "landscape-right",
      ])
    // GSEvent (earlier runtimes): 3 landscape right, 4 landscape left.
    #expect(ScreenSharingSimulatorOrientation.allCases.map(SimulatorDeviceControl.gsEventValue) == [1, 4, 2, 3])
  }
}
