import CoreGraphics
import Foundation
import Testing

@testable import SimulatorPane

@Suite struct SimulatorChromeLayoutTests {
  /// DeviceKit's phone12 chrome, trimmed to what layout reads.
  static let definition = try! SimulatorChromeDefinition(
    json: Data(
      """
      {
        "identifier": "com.apple.dt.devicekit.chrome.phone12",
        "images": { "sizing": { "leftWidth": 18, "rightWidth": 18, "topHeight": 18, "bottomHeight": 18 } },
        "paths": { "simpleOutsideBorder": { "cornerRadiusX": 80 } },
        "inputs": [
          { "name": "action", "image": "Mute BTN", "anchor": "left", "align": "leading",
            "offsets": { "normal": { "x": 8, "y": 180 }, "rollover": { "x": 3, "y": 180 } } },
          { "name": "power", "image": "X_Power BTN", "anchor": "right", "align": "leading",
            "offsets": { "normal": { "x": -8, "y": 293 }, "rollover": { "x": -3, "y": 293 } } }
        ]
      }
      """.utf8))

  static let imageSizes = ["Mute BTN": CGSize(width: 16, height: 34), "X_Power BTN": CGSize(width: 16, height: 101)]

  @Test func screenSitsInsideTheBezelAndButtonsHangOutside() {
    let layout = SimulatorChromeLayout(
      definition: Self.definition, screen: CGSize(width: 420, height: 912)
    ) { Self.imageSizes[$0] }
    // Each side button sticks out by its depth minus its inward offset; the canvas grows to fit
    // the rolled-out position, so nothing is clipped when the pointer slides a button out.
    #expect(layout.frame == CGRect(x: 13, y: 0, width: 456, height: 948))
    #expect(layout.screen == CGRect(x: 31, y: 18, width: 420, height: 912))
    #expect(layout.canvas == CGSize(width: 482, height: 948))
    let action = layout.buttons.first { $0.input.name == "action" }
    #expect(action?.frame == CGRect(x: 5, y: 180, width: 16, height: 34))
    #expect(action?.rolloverFrame == CGRect(x: 0, y: 180, width: 16, height: 34))
    let power = layout.buttons.first { $0.input.name == "power" }
    #expect(power?.frame == CGRect(x: 461, y: 293, width: 16, height: 101))
    #expect(power?.rolloverFrame.maxX == layout.canvas.width)
  }

  @Test func buttonsWithoutArtworkAreLeftOff() {
    let layout = SimulatorChromeLayout(definition: Self.definition, screen: CGSize(width: 420, height: 912)) { _ in nil
    }
    #expect(layout.buttons.isEmpty)
    #expect(layout.canvas == layout.frame.size)
  }

  @Test(arguments: 0..<4) func screenFollowsTheTurnedDevice(turns: Int) {
    let canvas = CGSize(width: 480, height: 960)
    let screen = CGRect(x: 30, y: 18, width: 420, height: 912)
    let turned = SimulatorDeviceCanvas.rotate(screen, in: canvas, quarterTurns: turns)
    let turnedCanvas = turns.isMultiple(of: 2) ? canvas : CGSize(width: canvas.height, height: canvas.width)
    #expect(CGRect(origin: .zero, size: turnedCanvas).contains(turned))
    #expect(turned.width == (turns.isMultiple(of: 2) ? 420 : 912))
    // Turning the rest of the way round lands back where it started.
    let back = SimulatorDeviceCanvas.rotate(turned, in: turnedCanvas, quarterTurns: 4 - turns)
    #expect(back == screen)
  }

  @Test func aClockwiseTurnPutsTheTopEdgeOnTheRight() {
    // A strip along the top of a portrait canvas ends up along the right once turned clockwise.
    let strip = SimulatorDeviceCanvas.rotate(
      CGRect(x: 0, y: 0, width: 100, height: 10), in: CGSize(width: 100, height: 200), quarterTurns: 1)
    #expect(strip == CGRect(x: 190, y: 0, width: 10, height: 100))
  }

  @Test func turningAcrossPortraitGoesTheShortWay() {
    // Portrait (0°) to landscape left (270°) is a quarter turn back, not three forward.
    #expect(SimulatorDeviceCanvas.shortestTurn(from: 0, to: 270) == -90)
    #expect(SimulatorDeviceCanvas.shortestTurn(from: 270, to: 0) == 90)
    #expect(SimulatorDeviceCanvas.shortestTurn(from: 90, to: 180) == 90)
    #expect(SimulatorDeviceCanvas.shortestTurn(from: 180, to: 90) == -90)
  }
}
