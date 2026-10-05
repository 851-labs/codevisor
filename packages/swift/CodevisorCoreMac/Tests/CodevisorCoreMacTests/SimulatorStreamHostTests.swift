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

  @Test("Frames fit the encoder: scaled into 3840×2160, even sides")
  func outputSizes() {
    // A tall iPhone framebuffer is taller than the encoder allows.
    #expect(SimulatorScreenCapture.outputSize(width: 1260, height: 2736) == CGSize(width: 994, height: 2160))
    #expect(SimulatorScreenCapture.outputSize(width: 2736, height: 1260) == CGSize(width: 2736, height: 1260))
    #expect(SimulatorScreenCapture.outputSize(width: 422, height: 514) == CGSize(width: 422, height: 514))
  }

  @Test("Screens are mounted as Device Hub draws them: only the Duo's inner screen is sideways")
  func screenMounting() {
    // An iPad's panel is rotated 270° and its main screen 90° back; a Watch's 90° and 270°.
    #expect(SimulatorRuntime.screenTurns(nativeRotation: 270, mainScreenOrientation: .pi / 2) == 0)
    #expect(SimulatorRuntime.screenTurns(nativeRotation: 90, mainScreenOrientation: 3 * .pi / 2) == 0)
    #expect(SimulatorRuntime.screenTurns(nativeRotation: 0, mainScreenOrientation: 0) == 0)
    // The iPhone Duo's inner screen: turned a quarter clockwise, it opens in landscape.
    #expect(SimulatorRuntime.screenTurns(nativeRotation: 270, mainScreenOrientation: 0) == 1)
    #expect(SimulatorRuntime.screenTurns(nativeRotation: 90, mainScreenOrientation: 0) == 3)
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

  @Test("Device state is IOKit's compact serialization, small enough for the guest's relay")
  func deviceState() {
    let hinge = SimulatorDeviceControl.deviceState(source: "hinge-slider-control", type: "range", value: .integer(180))
    #expect(
      String(decoding: hinge, as: UTF8.self)
        == "<dict><key>source</key><string>hinge-slider-control</string><key>type</key><string>range</string>"
        + "<key>value</key><integer>180</integer></dict>")
    // locationd refused a 328-byte payload; stay well under it.
    #expect(hinge.count < 200)
    let escaped = SimulatorDeviceControl.deviceState(source: "a<b", type: "c&d", value: .string("e>f"))
    #expect(String(decoding: escaped, as: UTF8.self).contains("<string>a&lt;b</string>"))
    #expect(String(decoding: escaped, as: UTF8.self).contains("<string>c&amp;d</string>"))
    #expect(String(decoding: escaped, as: UTF8.self).contains("<string>e&gt;f</string>"))
  }
}
