#!/usr/bin/env swift
import CoreGraphics
import Foundation

struct Master {
  let name: String
  let stroke: Double
  let archJoin: Double
  let height: Double
  let eyeRadius: Double
  let eyeHoleRadius: Double
  let badgeRadius: Double
  let badgeClearRadius: Double
  let plusLength: Double
  let plusThickness: Double
  let column: Double
}

let masters = [
  Master(
    name: "Ultralight", stroke: 2.2, archJoin: 1, height: 74.15, eyeRadius: 8.6, eyeHoleRadius: 10.4,
    badgeRadius: 18.29, badgeClearRadius: 21.36,
    plusLength: 23.7, plusThickness: 3.05, column: 515.649),
  Master(
    name: "Regular", stroke: 7.05, archJoin: 0.8, height: 76.4, eyeRadius: 10.2, eyeHoleRadius: 9.8,
    badgeRadius: 19.69, badgeClearRadius: 25.39,
    plusLength: 24.46, plusThickness: 5.1, column: 1403.58),
  Master(
    name: "Black", stroke: 14.15, archJoin: 0.55, height: 80.2, eyeRadius: 11.6, eyeHoleRadius: 8.6,
    badgeRadius: 20.95, badgeClearRadius: 27.3,
    plusLength: 27.93, plusThickness: 7.8, column: 2884.57),
]

let baselineS = 696.0
let capHeight = 70.459
let sideBearing = 9.77
let mascotWidth = 176.0
let mascotHeight = 226.0
let footCorner = 20.0
let footInnerCorner = 10.0
let gapHalfWidth = 32.0
let gapHeight = 62.0
let headCorner = 63.0
let eyeHeight = 146.0

struct Corner {
  var point: CGPoint
  var radius: Double
}

enum Segment {
  case move(CGPoint)
  case line(CGPoint)
  case cubic(CGPoint, CGPoint, CGPoint)
  case close
}

func normalized(_ v: CGPoint) -> CGPoint {
  let length = hypot(v.x, v.y)
  return CGPoint(x: v.x / length, y: v.y / length)
}

func arc(center: CGPoint, radius: Double, from start: Double, sweep: Double, pieces: Int) -> [Segment] {
  let step = sweep / Double(pieces)
  let handle = 4 / 3 * tan(step / 4) * radius
  return (0..<pieces).map { index in
    let a0 = start + step * Double(index)
    let a1 = a0 + step
    let p0 = CGPoint(x: center.x + radius * cos(a0), y: center.y + radius * sin(a0))
    let p1 = CGPoint(x: center.x + radius * cos(a1), y: center.y + radius * sin(a1))
    let c0 = CGPoint(x: p0.x - handle * sin(a0), y: p0.y + handle * cos(a0))
    let c1 = CGPoint(x: p1.x + handle * sin(a1), y: p1.y - handle * cos(a1))
    return .cubic(c0, c1, p1)
  }
}

func roundedPolygon(_ corners: [Corner]) -> [Segment] {
  var segments: [Segment] = []
  for (index, corner) in corners.enumerated() {
    let previous = corners[(index + corners.count - 1) % corners.count].point
    let next = corners[(index + 1) % corners.count].point
    let incoming = normalized(CGPoint(x: corner.point.x - previous.x, y: corner.point.y - previous.y))
    let outgoing = normalized(CGPoint(x: next.x - corner.point.x, y: next.y - corner.point.y))
    let turn = atan2(
      incoming.x * outgoing.y - incoming.y * outgoing.x, incoming.x * outgoing.x + incoming.y * outgoing.y)
    let reach = corner.radius * tan(abs(turn) / 2)
    let start = CGPoint(x: corner.point.x - incoming.x * reach, y: corner.point.y - incoming.y * reach)
    let side = turn > 0 ? 1.0 : -1.0
    let normal = CGPoint(x: -incoming.y * side, y: incoming.x * side)
    let center = CGPoint(x: start.x + normal.x * corner.radius, y: start.y + normal.y * corner.radius)
    let startAngle = atan2(start.y - center.y, start.x - center.x)
    segments.append(index == 0 ? .move(start) : .line(start))
    segments += arc(center: center, radius: corner.radius, from: startAngle, sweep: turn, pieces: 2)
  }
  segments.append(.close)
  return segments
}

func circle(center: CGPoint, radius: Double, clockwise: Bool = false) -> [Segment] {
  let sweep = clockwise ? -2 * Double.pi : 2 * Double.pi
  let start = CGPoint(x: center.x + radius, y: center.y)
  return [.move(start)] + arc(center: center, radius: radius, from: 0, sweep: sweep, pieces: 4) + [.close]
}

func plus(center: CGPoint, length: Double, thickness: Double) -> [Segment] {
  let arm = length / 2
  let half = thickness / 2
  let cap = half
  let points: [(Double, Double, Double)] = [
    (half, half, 0), (arm, half, cap), (arm, -half, cap), (half, -half, 0),
    (half, -arm, cap), (-half, -arm, cap), (-half, -half, 0), (-arm, -half, cap),
    (-arm, half, cap), (-half, half, 0), (-half, arm, cap), (half, arm, cap),
  ]
  return roundedPolygon(
    points.reversed().map { Corner(point: CGPoint(x: center.x + $0.0, y: center.y + $0.1), radius: $0.2) })
}

struct Body {
  let width: Double
  let bottom: Double
  let scale: Double
  let gapHalfWidth: Double
  let archHeight: Double
  let footInnerRadius: Double
  let silhouette: [Segment]
  let center: (Double) -> CGPoint
}

let archCenterlineTop: Double = {
  let thinnest = masters[0]
  return gapHeight + thinnest.stroke / 2 / (thinnest.height / mascotHeight)
}()

func body(height: Double, stroke: Double) -> Body {
  let scale = height / mascotHeight
  let bottom = capHeight / 2 - height / 2
  func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * scale, y: bottom + y * scale) }
  let straight = (gapHeight - gapHalfWidth) / gapHalfWidth
  let gap = (archCenterlineTop * scale - stroke / 2) / (1 + straight)
  let arch = gap * straight
  let footInner = gap * footInnerCorner / gapHalfWidth
  let halfWidth = mascotWidth / 2 * scale
  func q(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: bottom + y) }
  let corners = [
    Corner(point: q(-halfWidth, 0), radius: footCorner * scale),
    Corner(point: q(-gap, 0), radius: footInner),
    Corner(point: q(-gap, arch + gap), radius: gap),
    Corner(point: q(gap, arch + gap), radius: gap),
    Corner(point: q(gap, 0), radius: footInner),
    Corner(point: q(halfWidth, 0), radius: footCorner * scale),
    Corner(point: q(halfWidth, mascotHeight * scale), radius: headCorner * scale),
    Corner(point: q(-halfWidth, mascotHeight * scale), radius: headCorner * scale),
  ]
  return Body(
    width: 2 * halfWidth, bottom: bottom, scale: scale, gapHalfWidth: gap, archHeight: arch,
    footInnerRadius: footInner, silhouette: roundedPolygon(corners), center: { y in p(0, y) })
}

func reversed(_ path: [Segment]) -> [Segment] {
  var points: [CGPoint] = []
  var pieces: [Segment] = []
  for segment in path {
    switch segment {
    case .move(let p): points.append(p)
    case .line(let p): pieces.append(.line(points.last!)); points.append(p)
    case .cubic(let c0, let c1, let p): pieces.append(.cubic(c1, c0, points.last!)); points.append(p)
    case .close: break
    }
  }
  return [.move(points.last!)] + pieces.reversed() + [.close]
}

func hole(_ body: Body, stroke: Double, archJoin: Double) -> [Segment] {
  let halfWidth = body.width / 2 - stroke
  let top = body.bottom + mascotHeight * body.scale - stroke
  let topRadius = max(0, headCorner * body.scale - stroke)
  let archRadius = body.gapHalfWidth + stroke * archJoin
  let archCenter = CGPoint(x: 0, y: body.bottom + body.archHeight + stroke * (1 - archJoin))
  let slotWidth = halfWidth - archRadius
  let open = slotWidth > 0
  let footY =
    open
    ? min(body.bottom + stroke, archCenter.y) : archCenter.y + sqrt(archRadius * archRadius - halfWidth * halfWidth)
  let slotInner = open ? archRadius : halfWidth
  let outerRadius = open ? min(max(0, footCorner * body.scale - stroke), slotWidth / 2) : 0
  let innerRadius = open ? min(max(0, body.footInnerRadius - stroke), slotWidth / 2, archCenter.y - footY) : 0
  let entry = atan2(footY - archCenter.y, -halfWidth)
  let archAngle = open ? Double.pi : max(Double.pi / 2, entry)
  let archSweep = Double.pi / 2 - archAngle
  func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }
  func corner(_ x: Double, _ y: Double, _ radius: Double, _ from: Double) -> [Segment] {
    arc(center: point(x, y), radius: radius, from: from, sweep: Double.pi / 2, pieces: 2)
  }
  let archStart = point(archCenter.x + archRadius * cos(archAngle), archCenter.y + archRadius * sin(archAngle))
  let archEnd = point(-archStart.x, archStart.y)
  var path: [Segment] = [.move(point(-halfWidth, top - topRadius)), .line(point(-halfWidth, footY + outerRadius))]
  path += corner(-halfWidth + outerRadius, footY + outerRadius, outerRadius, Double.pi)
  path.append(.line(point(-slotInner - innerRadius, footY)))
  path += corner(-slotInner - innerRadius, footY + innerRadius, innerRadius, 3 * Double.pi / 2)
  path.append(.line(archStart))
  path += arc(center: archCenter, radius: archRadius, from: archAngle, sweep: archSweep, pieces: 2)
  path += arc(center: archCenter, radius: archRadius, from: Double.pi / 2, sweep: archSweep, pieces: 2)
  path.append(.line(point(archEnd.x, footY + innerRadius)))
  path += corner(slotInner + innerRadius, footY + innerRadius, innerRadius, Double.pi)
  path.append(.line(point(halfWidth - outerRadius, footY)))
  path += corner(halfWidth - outerRadius, footY + outerRadius, outerRadius, 3 * Double.pi / 2)
  path.append(.line(point(halfWidth, top - topRadius)))
  path += corner(halfWidth - topRadius, top - topRadius, topRadius, 0)
  path.append(.line(point(-halfWidth + topRadius, top)))
  path += corner(-halfWidth + topRadius, top - topRadius, topRadius, Double.pi / 2)
  path.append(.close)
  return reversed(path)
}

struct Layers {
  var base: [Segment]
  var badge: (clear: [Segment], disc: [Segment], plus: [Segment])?
  var halfAdvance: Double
}

func layers(_ master: Master, filled: Bool, badged: Bool) -> Layers {
  let shape = body(height: master.height, stroke: master.stroke)
  let eye = shape.center(eyeHeight)
  let base =
    filled
    ? shape.silhouette + circle(center: eye, radius: master.eyeHoleRadius, clockwise: true)
    : shape.silhouette + hole(shape, stroke: master.stroke, archJoin: master.archJoin)
      + circle(center: eye, radius: master.eyeRadius)
  var result = Layers(base: base, badge: nil, halfAdvance: shape.width / 2)
  if badged {
    let center = CGPoint(x: shape.width / 2 + 2, y: shape.bottom + mascotHeight * shape.scale - 9)
    result.badge = (
      circle(center: center, radius: master.badgeClearRadius),
      circle(center: center, radius: master.badgeRadius),
      plus(center: center, length: master.plusLength, thickness: master.plusThickness)
    )
  }
  return result
}

func format(_ value: Double) -> String {
  let rounded = (value * 10000).rounded() / 10000
  return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
}

func serialize(_ segments: [Segment], shift: Double) -> String {
  func p(_ point: CGPoint) -> String { "\(format(point.x + shift)) \(format(-point.y))" }
  return segments.map { segment in
    switch segment {
    case .move(let a): "M\(p(a))"
    case .line(let a): "L\(p(a))"
    case .cubic(let c0, let c1, let a): "C\(p(c0)) \(p(c1)) \(p(a))"
    case .close: "Z"
    }
  }.joined()
}

let badgeStyles = """
  .defaults {-sfsymbols-draw-reverses-motion-groups:false}

  .monochrome-0 {-sfsymbols-motion-group:1}
  .monochrome-1 {opacity:0.0;-sfsymbols-clear-behind:true;-sfsymbols-motion-group:0}
  .monochrome-2 {-sfsymbols-motion-group:0;-sfsymbols-always-pulses:true}
  .monochrome-3 {opacity:0.0;-sfsymbols-clear-behind:true;-sfsymbols-motion-group:0;-sfsymbols-always-pulses:true}

  .multicolor-0:tintColor {-sfsymbols-motion-group:1}
  .multicolor-1:tintColor {opacity:0.0;-sfsymbols-clear-behind:true;-sfsymbols-motion-group:0}
  .multicolor-2:systemGreenColor {-sfsymbols-motion-group:0;-sfsymbols-always-pulses:true}
  .multicolor-3:white {-sfsymbols-motion-group:0;-sfsymbols-always-pulses:true}

  .hierarchical-0:secondary {-sfsymbols-motion-group:1}
  .hierarchical-1:primary {opacity:0.0;-sfsymbols-clear-behind:true;-sfsymbols-motion-group:0}
  .hierarchical-2:primary {-sfsymbols-motion-group:0;-sfsymbols-always-pulses:true}
  .hierarchical-3:primary {opacity:0.0;-sfsymbols-clear-behind:true;-sfsymbols-motion-group:0;-sfsymbols-always-pulses:true}

  .SFSymbolsPreviewWireframe {fill:none;opacity:1.0;stroke:black;stroke-width:0.5}
  """

let plainStyles = """
  .monochrome-0 {}
  .multicolor-0:tintColor {}
  .hierarchical-0:primary {}

  .SFSymbolsPreviewWireframe {fill:none;opacity:1.0;stroke:black;stroke-width:0.5}
  """

func guide(_ id: String, _ y: Double) -> String {
  "  <line id=\"\(id)\" style=\"fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;\" x1=\"263\" x2=\"3036\" y1=\"\(format(y))\" y2=\"\(format(y))\"/>"
}

func template(name: String, filled: Bool, badged: Bool) -> String {
  var margins: [String] = []
  var groups: [String] = []
  for master in masters {
    let symbol = layers(master, filled: filled, badged: badged)
    let shift = symbol.halfAdvance + sideBearing
    let advance = 2 * shift
    for (side, x) in [("left", master.column), ("right", master.column + advance)] {
      margins.append(
        "  <line id=\"\(side)-margin-\(master.name)-S\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;\" x1=\"\(format(x))\" x2=\"\(format(x))\" y1=\"600.785\" y2=\"720.121\"/>"
      )
    }
    var paths: [(String, [Segment])] = []
    if let badge = symbol.badge {
      paths = [
        ("monochrome-0 multicolor-0:tintColor hierarchical-0:secondary", symbol.base),
        ("monochrome-1 multicolor-1:tintColor hierarchical-1:primary", badge.clear),
        ("monochrome-2 multicolor-2:systemGreenColor hierarchical-2:primary", badge.disc),
        ("monochrome-3 multicolor-3:white hierarchical-3:primary", badge.plus),
      ]
    } else {
      paths = [("monochrome-0 multicolor-0:tintColor hierarchical-0:primary", symbol.base)]
    }
    let body = paths.map {
      "   <path class=\"\($0.0) SFSymbolsPreviewWireframe\" d=\"\(serialize($0.1, shift: shift))\"/>"
    }
    groups.append(
      "  <g id=\"\(master.name)-S\" transform=\"matrix(1 0 0 1 \(format(master.column)) \(format(baselineS)))\">\n"
        + body.joined(separator: "\n") + "\n  </g>")
  }
  let guides = [
    guide("Baseline-S", 696), guide("Capline-S", 625.541),
    guide("Baseline-M", 1126), guide("Capline-M", 1055.54),
    guide("Baseline-L", 1556), guide("Capline-L", 1485.54),
  ]
  return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE svg
    PUBLIC "-//W3C//DTD SVG 1.1//EN"
           "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
    <svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 3300 2200">
     <style>\(badged ? badgeStyles : plainStyles)
    </style>
     <g id="Notes">
      <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
      <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.7.0</text>
      <text id="descriptive-name" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1969)">\(name)</text>
     </g>
     <g id="Guides">
    \(guides.joined(separator: "\n"))
    \(margins.joined(separator: "\n"))
     </g>
     <g id="Symbols">
    \(groups.joined(separator: "\n"))
     </g>
    </svg>

    """
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let catalog = root.appending(path: "packages/swift/CodevisorUI/Sources/CodevisorUI/Resources/MascotSymbols.xcassets")
let staging = try FileManager.default.url(
  for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: catalog.deletingLastPathComponent(), create: true
).appending(path: "MascotSymbols.xcassets")
try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
try Data("{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n".utf8)
  .write(to: staging.appending(path: "Contents.json"))
for (name, filled, badged) in [
  ("mascot", false, false), ("mascot.fill", true, false),
  ("mascot.badge.plus", false, true), ("mascot.fill.badge.plus", true, true),
] {
  let symbolset = staging.appending(path: "\(name).symbolset")
  try FileManager.default.createDirectory(at: symbolset, withIntermediateDirectories: true)
  try Data(template(name: name, filled: filled, badged: badged).utf8).write(
    to: symbolset.appending(path: "\(name).svg"))
  try Data(
    """
    {
      "info" : {
        "author" : "xcode",
        "version" : 1
      },
      "symbols" : [
        {
          "filename" : "\(name).svg",
          "idiom" : "universal"
        }
      ]
    }

    """.utf8
  ).write(to: symbolset.appending(path: "Contents.json"))
}

if FileManager.default.fileExists(atPath: catalog.path) {
  _ = try FileManager.default.replaceItemAt(catalog, withItemAt: staging)
} else {
  try FileManager.default.moveItem(at: staging, to: catalog)
}
