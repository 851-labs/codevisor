import CoreGraphics
import Foundation
import SwiftUI
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
    // Each side button would stick out by its depth minus its inward offset (8 here); as Device
    // Hub draws them it stands just 3 proud, its rolled-out position moving in with it. The canvas
    // grows to fit that position, so nothing is clipped when the pointer slides a button out.
    #expect(layout.frame == CGRect(x: 8, y: 0, width: 456, height: 948))
    #expect(layout.screen == CGRect(x: 26, y: 18, width: 420, height: 912))
    #expect(layout.canvas == CGSize(width: 472, height: 948))
    let action = layout.buttons.first { $0.input.name == "action" }
    #expect(action?.frame == CGRect(x: 5, y: 180, width: 16, height: 34))
    #expect(action?.rolloverFrame == CGRect(x: 0, y: 180, width: 16, height: 34))
    let power = layout.buttons.first { $0.input.name == "power" }
    #expect(power?.frame == CGRect(x: 451, y: 293, width: 16, height: 101))
    #expect(power?.rolloverFrame.maxX == layout.canvas.width)
  }

  @Test func buttonsArePlacedAgainstTheDevicesVisibleEdge() {
    // A composite with a 10-point clear margin on its right: the power button hangs off the
    // device's edge, not the margin's.
    let margins = SimulatorChromeLayout.Margins(left: 0, top: 0, right: 10, bottom: 0)
    let layout = SimulatorChromeLayout(
      definition: Self.definition, screen: CGSize(width: 420, height: 912), margins: margins
    ) { Self.imageSizes[$0] }
    let power = layout.buttons.first { $0.input.name == "power" }
    #expect(power.map { $0.frame.maxX - (layout.frame.maxX - 10) } == 3)
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

  @Test func artworkDrawnForTheOtherEdgeIsTurnedToLieAlongIt() {
    // The iPhone Duo's inner chrome reuses its cover's top-edge volume button (63×16) on its
    // left side, and its side power button (16×107) on its top.
    let definition = try! SimulatorChromeDefinition(
      json: Data(
        """
        {
          "identifier": "phone14",
          "images": { "sizing": { "leftWidth": 17, "rightWidth": 17, "topHeight": 17, "bottomHeight": 17 } },
          "inputs": [
            { "name": "volume-up", "image": "Vol BTN", "anchor": "left", "align": "leading",
              "offsets": { "normal": { "x": 8, "y": 114 }, "rollover": { "x": 5, "y": 114 } } },
            { "name": "power", "image": "X Power BTN", "anchor": "top", "align": "leading",
              "offsets": { "normal": { "x": 196, "y": 8 }, "rollover": { "x": 196, "y": 4 } } }
          ]
        }
        """.utf8))
    let sizes = ["Vol BTN": CGSize(width: 63, height: 16), "X Power BTN": CGSize(width: 16, height: 107)]
    let layout = SimulatorChromeLayout(definition: definition, screen: CGSize(width: 669, height: 951)) { sizes[$0] }
    let volume = layout.buttons.first { $0.input.name == "volume-up" }
    #expect(volume?.turned == true)
    #expect(volume?.frame.size == CGSize(width: 16, height: 63))
    // Hanging out of the left edge as an upright button would, just 3 proud.
    #expect(volume.map { layout.frame.minX - $0.frame.minX } == 3)
    let power = layout.buttons.first { $0.input.name == "power" }
    #expect(power?.turned == true)
    #expect(power?.frame.size == CGSize(width: 107, height: 16))
    #expect(power.map { layout.frame.minY - $0.frame.minY } == 3)
    // Artwork that already lies along its edge is left as drawn.
    #expect(
      Self.definition.inputs.map { inputs in
        inputs.allSatisfy { !SimulatorChromeLayout.isTurned($0, size: Self.imageSizes[$0.image ?? ""] ?? .zero) }
      } == true)
  }

  @Test func foldingTurnsTheHalvesAsDeviceHubDoes() {
    // Flat, nothing turns; a book tilts both halves alike; shut, the left half has swung right over.
    #expect(SimulatorFold.angles(hinge: 180) == (left: 0, right: 0))
    let book = SimulatorFold.angles(hinge: 130)
    #expect(book.left == book.right && book.left > 0 && book.left < 30)
    #expect(SimulatorFold.angles(hinge: 0) == (left: 180, right: 0))
    // Closing past a book carries on smoothly from it.
    let nearBook = SimulatorFold.angles(hinge: 129.9)
    #expect(abs(nearBook.left - book.left) < 0.5 && abs(nearBook.right - book.right) < 0.5)
    #expect(SimulatorFold.closing(hinge: 130) == 0 && SimulatorFold.closing(hinge: 0) == 1)
  }

  @Test(arguments: [CGPoint(x: 40, y: 30), CGPoint(x: 700, y: 600), CGPoint(x: 499, y: 5)])
  func aTouchOnATiltedHalfLandsWhereItWasDrawnFrom(flat: CGPoint) {
    let center = CGPoint(x: 500, y: 350)
    let depth = SimulatorFold.depth(width: 1000)
    let left = flat.x < center.x
    let angle = SimulatorFold.angles(hinge: 130)
    let transform = SimulatorFold.tilt(left ? angle.left : angle.right, left: left, center: center, depth: depth)
    let w = flat.x * transform.m13 + flat.y * transform.m23 + transform.m33
    let drawn = CGPoint(
      x: (flat.x * transform.m11 + flat.y * transform.m21 + transform.m31) / w,
      y: (flat.x * transform.m12 + flat.y * transform.m22 + transform.m32) / w)
    // A tilted half is drawn foreshortened toward the hinge, and flattening undoes it.
    #expect(abs(drawn.x - center.x) < abs(flat.x - center.x) + 0.001)
    let back = SimulatorFold.flatten(drawn, hinge: 130, center: center, depth: depth)
    #expect(abs(back.x - flat.x) < 0.01 && abs(back.y - flat.y) < 0.01)
  }

  private static func apply(_ transform: ProjectionTransform, _ point: CGPoint) -> CGPoint {
    let w = point.x * transform.m13 + point.y * transform.m23 + transform.m33
    return CGPoint(
      x: (point.x * transform.m11 + point.y * transform.m21 + transform.m31) / w,
      y: (point.x * transform.m12 + point.y * transform.m22 + transform.m32) / w)
  }

  /// Where a point in space is drawn, seen from `depth` in front of `center` (z toward you).
  private static func perspective(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat, center: CGPoint, depth: CGFloat) -> CGPoint
  {
    let scale = depth / (depth - z)
    return CGPoint(x: center.x + (x - center.x) * scale, y: center.y + (y - center.y) * scale)
  }

  @Test(arguments: [true, false])
  func aSliceBehindAHalfsFaceIsDrawnWhereItStandsInSpace(left: Bool) {
    let center = CGPoint(x: 500, y: 350)
    let depth = SimulatorFold.depth(width: 1000)
    let degrees = 60.0, inset: CGFloat = 20
    let transform = SimulatorFold.tilt(degrees, left: left, center: center, depth: depth, inset: inset)
    let c = CGFloat(cos(degrees * .pi / 180)), s = CGFloat(sin(degrees * .pi / 180))
    let sign: CGFloat = left ? -1 : 1
    for flat in [CGPoint(x: center.x + sign * 400, y: 50), CGPoint(x: center.x + sign * 120, y: 640)] {
      // `inset` behind the screen, `a` out from the hinge, turned toward you about it.
      let a = abs(flat.x - center.x)
      let expected = Self.perspective(
        center.x + sign * (a * c + inset * s), flat.y, a * s - inset * c, center: center, depth: depth)
      let drawn = Self.apply(transform, flat)
      #expect(abs(drawn.x - expected.x) < 0.001 && abs(drawn.y - expected.y) < 0.001)
    }
  }

  @Test func aHalfsBodyIsTheHullOfItsRoundedOutlineCutAtTheHinge() {
    let rect = CGRect(x: 100, y: 50, width: 400, height: 300)
    let outline = SimulatorFold.outline(rect, corners: .init(all: 40))
    // Every point lies on the rounded rectangle, inside its frame, and the corners are rounded off.
    #expect(outline.allSatisfy { rect.insetBy(dx: -0.001, dy: -0.001).contains($0) })
    #expect(!outline.contains { abs($0.x - rect.minX) < 0.001 && abs($0.y - rect.minY) < 0.001 })
    let left = SimulatorFold.clip(outline, atX: 300, keepingLeft: true)
    #expect(left.allSatisfy { $0.x <= 300.001 } && left.contains { abs($0.x - 300) < 0.001 })
    // A convex outline is its own hull, and a point inside it doesn't change that.
    let hull = SimulatorFold.hull(left + [CGPoint(x: 200, y: 200)])
    #expect(hull.count <= left.count && !hull.contains(CGPoint(x: 200, y: 200)))
  }

  @Test func aBezelsOutlineIsWhereItsArtworkIsOpaque() throws {
    // A 40×30 image, opaque but for a margin: 2 left, 6 right, 1 top, 3 bottom.
    let context = try #require(
      CGContext(
        data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 0.2, alpha: 1))
    // Core Graphics counts y up from the bottom: 3 rows clear below, 1 above.
    context.fill(CGRect(x: 2, y: 3, width: 32, height: 26))
    let image = try #require(context.makeImage())
    #expect(SimulatorArtwork.opaqueBounds(image) == CGRect(x: 2, y: 1, width: 32, height: 26))
  }

  @Test func aCompositesMiddleStretchesFromAPlainStripAwayFromTheHingeMark() {
    let edges: [Double] = [0, 40, 600, 660]
    // Caps are taken whole; the middle from one point a quarter of the way along, clear of its center.
    #expect(SimulatorArtwork.plainSpan(edges, 0) == (0, 40))
    #expect(SimulatorArtwork.plainSpan(edges, 2) == (600, 60))
    #expect(SimulatorArtwork.plainSpan(edges, 1) == (180, 1))
  }

  @Test func turningANormalizedPointBackAndForthReturnsIt() {
    let point = CGPoint(x: 0.2, y: 0.7)
    for turns in 0..<4 {
      let there = SimulatorDeviceCanvas.unturn(point, turns: turns)
      let back = SimulatorDeviceCanvas.unturn(there, turns: 4 - turns)
      #expect(abs(back.x - point.x) < 1e-9 && abs(back.y - point.y) < 1e-9)
    }
  }
}
