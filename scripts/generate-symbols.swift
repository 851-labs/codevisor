#!/usr/bin/env swift
// Builds CodevisorUI's custom SF Symbols from packages/swift/CodevisorUI/Symbols/*.svg.
// Logos go through SwiftDraw, which outlines them into a symbol template; this script then sizes
// and places each glyph with the metrics Apple's own symbols use, so logos match neighboring SF
// Symbols. Line art (`lineArt` in overrides.json) is stroked here instead, at SF Symbols' own
// stroke width for every weight and image scale, so it gets bolder and lighter with the text.
// Requires `brew install swiftdraw`. Run with `swift scripts/generate-symbols.swift`.
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sources = root.appending(path: "packages/swift/CodevisorUI/Symbols")
let catalog = root.appending(path: "packages/swift/CodevisorUI/Sources/CodevisorUI/Resources/Symbols.xcassets")

// Every weight is drawn at each image scale. A template missing a scale renders nothing at that
// scale (iOS list rows use .large), and one with only small variants renders about 1.28x too big.
// Logos look the same at every weight, as Apple's `apple.logo` does, so they get the three masters
// Xcode interpolates between.
let weights = ["Ultralight", "Regular", "Black"]
// Glyph size of each image scale relative to medium, measured from SF Symbols.
let imageScales: [(name: String, ratio: Double)] = [("S", 0.787), ("M", 1), ("L", 1.276)]

// Line art draws all nine weights, each stroked as wide as SF Symbols' own line art at that weight
// and image scale, in cap heights. Measured from `circle` at 400 pt. Small and large symbols don't
// scale their strokes with the glyph: a small symbol is 0.79x as tall but its stroke only ~0.89x
// as wide. Every variant is drawn rather than interpolated, so outlines needn't match point for point.
let lineArtWeights = ["Ultralight", "Thin", "Light", "Regular", "Medium", "Semibold", "Bold", "Heavy", "Black"]
let lineArtStrokes: [String: [Double]] = [
  "S": [0.0295, 0.0451, 0.0758, 0.0988, 0.1150, 0.1272, 0.1435, 0.1669, 0.1881],
  "M": [0.0316, 0.0492, 0.0836, 0.1097, 0.1313, 0.1480, 0.1699, 0.2017, 0.2302],
  "L": [0.0331, 0.0528, 0.0911, 0.1202, 0.1473, 0.1679, 0.1953, 0.2350, 0.2668],
]

// Optical metrics measured from SF Symbols at regular weight, in cap heights. A square glyph is
// 1.27 tall with 0.176 side bearings; a circle, which covers less of its box, is 1.41 tall with
// 0.134 bearings. Coverage is the share of the bounding box inside the glyph's convex hull.
func opticalHeight(coverage: Double) -> Double { 1.27 + 0.65 * (1 - coverage) }
func sideBearing(coverage: Double) -> Double { max(0.09, 0.176 - 0.195 * (1 - coverage)) }
// Wide marks shrink to the widest everyday SF Symbols, such as `camera.fill` and `video.fill`.
let maxWidth = 1.69

// Per-symbol adjustments from Symbols/overrides.json. `height` pins the regular glyph's height in
// cap heights, so a family drawn on one grid keeps its shared proportions. `lineArt` marks a
// source drawn as centerlines, which this script strokes at each weight's width.
struct Overrides: Decodable {
  var height: Double?
  var lineArt: Bool?
}

enum Segment {
  case move(CGPoint)
  case line(CGPoint)
  case quad(CGPoint, CGPoint)
  case cubic(CGPoint, CGPoint, CGPoint)
  case close
}

func parse(_ d: String) -> [Segment] {
  let tokens = d.matches(of: #/[MLQCZ]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/#).map { String($0.output) }
  var segments: [Segment] = []
  var index = 0
  func point() -> CGPoint {
    defer { index += 2 }
    return CGPoint(x: Double(tokens[index])!, y: Double(tokens[index + 1])!)
  }
  while index < tokens.count {
    let command = tokens[index]
    index += 1
    switch command {
    case "M": segments.append(.move(point()))
    case "L": segments.append(.line(point()))
    case "Q": segments.append(.quad(point(), point()))
    case "C": segments.append(.cubic(point(), point(), point()))
    case "Z": segments.append(.close)
    default: fatalError("Unsupported path command \(command) in SwiftDraw output")
    }
  }
  return segments
}

func cgPath(_ segments: [Segment]) -> CGPath {
  let path = CGMutablePath()
  for segment in segments {
    switch segment {
    case .move(let p): path.move(to: p)
    case .line(let p): path.addLine(to: p)
    case .quad(let c, let p): path.addQuadCurve(to: p, control: c)
    case .cubic(let c1, let c2, let p): path.addCurve(to: p, control1: c1, control2: c2)
    case .close: path.closeSubpath()
    }
  }
  return path
}

func segments(_ path: CGPath) -> [Segment] {
  var segments: [Segment] = []
  path.applyWithBlock { element in
    let points = element.pointee.points
    switch element.pointee.type {
    case .moveToPoint: segments.append(.move(points[0]))
    case .addLineToPoint: segments.append(.line(points[0]))
    case .addQuadCurveToPoint: segments.append(.quad(points[0], points[1]))
    case .addCurveToPoint: segments.append(.cubic(points[0], points[1], points[2]))
    case .closeSubpath: segments.append(.close)
    @unknown default: fatalError("Unsupported path element")
    }
  }
  return segments
}

// A line-art source is a stroked <circle> or <path> per shape, each with round caps and joins.
// A shape that also has a fill, such as a dot, is filled and then stroked, so it grows with the
// weight like the lines around it. Its `stroke-width` is only a preview; each weight sets its own.
struct LineArtShape {
  var centerline: CGPath
  var filled: Bool
}

func attribute(_ name: String, in tag: Substring) -> String? {
  tag.firstMatch(of: try! Regex("\\s\(name)=\"([^\"]*)\"")).flatMap { $0.output[1].substring.map(String.init) }
}

func lineArt(_ source: URL) throws -> [LineArtShape] {
  let svg = try String(contentsOf: source, encoding: .utf8)
  let name = source.lastPathComponent
  guard let root = svg.firstMatch(of: #/<svg\b[^>]*>/#)?.output else { fatalError("\(name): no <svg> element") }
  let rootFill = attribute("fill", in: root)
  let rootStroke = attribute("stroke", in: root)
  return svg.matches(of: #/<([a-z]+)\b[^>]*>/#).compactMap { match -> LineArtShape? in
    let tag = match.output.0
    let fill = attribute("fill", in: tag) ?? rootFill
    let stroke = attribute("stroke", in: tag) ?? rootStroke
    let centerline: CGPath
    switch match.output.1 {
    case "svg": return nil
    case "path": centerline = centerlinePath(attribute("d", in: tag)!, in: name)
    case "circle":
      let number = { (key: String) in Double(attribute(key, in: tag)!)! }
      let r = number("r")
      centerline = CGPath(
        ellipseIn: CGRect(x: number("cx") - r, y: number("cy") - r, width: r * 2, height: r * 2), transform: nil)
    case let element: fatalError("\(name): line art only supports <path> and <circle>, found <\(element)>")
    }
    guard let stroke, stroke != "none" else { fatalError("\(name): every line-art shape needs a stroke: \(tag)") }
    return LineArtShape(centerline: centerline, filled: fill != nil && fill != "none")
  }
}

// Absolute M, L, H, V, C, circular A and Z commands, which is all the line-art sources use.
func centerlinePath(_ d: String, in name: String) -> CGPath {
  let tokens = d.matches(of: #/[A-Za-z]|-?(?:\d+\.?\d*|\.\d+)/#).map { String($0.output) }
  let path = CGMutablePath()
  var index = 0
  var command = ""
  var current = CGPoint.zero
  func number() -> Double {
    defer { index += 1 }
    return Double(tokens[index])!
  }
  func point() -> CGPoint { CGPoint(x: number(), y: number()) }
  while index < tokens.count {
    if tokens[index].first!.isLetter {
      command = tokens[index]
      index += 1
    }
    switch command {
    case "M":
      current = point()
      path.move(to: current)
      command = "L"
    case "L": current = point()
    case "H": current.x = number()
    case "V": current.y = number()
    case "C":
      let (c1, c2, end) = (point(), point(), point())
      path.addCurve(to: end, control1: c1, control2: c2)
      current = end
      continue
    case "A":
      let (rx, ry, rotation, largeArc, sweep, end) = (
        number(), number(), number(), number() != 0, number() != 0, point()
      )
      guard rx == ry, rotation == 0 else { fatalError("\(name): only circular, unrotated arcs are supported") }
      addArc(to: path, from: current, to: end, radius: rx, largeArc: largeArc, sweep: sweep)
      current = end
      continue
    case "Z":
      path.closeSubpath()
      current = path.currentPoint
      continue
    default: fatalError("\(name): unsupported path command \(command) in line art; use absolute M L H V C A Z")
    }
    path.addLine(to: current)
  }
  return path
}

// SVG's endpoint arc as a center arc (SVG 1.1 appendix F.6.5, with rx == ry and no rotation).
func addArc(to path: CGMutablePath, from start: CGPoint, to end: CGPoint, radius: Double, largeArc: Bool, sweep: Bool) {
  let half = CGPoint(x: (start.x - end.x) / 2, y: (start.y - end.y) / 2)
  let squared = half.x * half.x + half.y * half.y
  let r = max(radius, squared.squareRoot())
  let coefficient = (largeArc == sweep ? -1.0 : 1) * max(0, (r * r - squared) / squared).squareRoot()
  let offset = CGPoint(x: coefficient * half.y, y: -coefficient * half.x)
  let center = CGPoint(x: offset.x + (start.x + end.x) / 2, y: offset.y + (start.y + end.y) / 2)
  let startAngle = atan2(half.y - offset.y, half.x - offset.x)
  var sweepAngle = atan2(-half.y - offset.y, -half.x - offset.x) - startAngle
  if sweep, sweepAngle < 0 { sweepAngle += 2 * .pi }
  if !sweep, sweepAngle > 0 { sweepAngle -= 2 * .pi }
  path.addArc(
    center: center, radius: r, startAngle: startAngle, endAngle: startAngle + sweepAngle, clockwise: sweepAngle < 0)
}

// The filled outline of every shape stroked at `width`, merged into one path.
func outline(_ shapes: [LineArtShape], transform: CGAffineTransform, width: Double) -> CGPath {
  shapes.reduce(CGMutablePath() as CGPath) { result, shape in
    var transform = transform
    let centerline = shape.centerline.copy(using: &transform)!
    var piece = centerline.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    if shape.filled { piece = piece.union(centerline) }
    return result.union(piece)
  }
}

func format(_ value: Double) -> String {
  let rounded = (value * 1000).rounded() / 1000
  return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
}

func serialize(_ segments: [Segment], _ transform: (CGPoint) -> CGPoint) -> String {
  func p(_ point: CGPoint) -> String {
    let t = transform(point)
    return "\(format(t.x)),\(format(t.y))"
  }
  return segments.map { segment in
    switch segment {
    case .move(let a): "M\(p(a))"
    case .line(let a): "L\(p(a))"
    case .quad(let c, let a): "Q\(p(c)) \(p(a))"
    case .cubic(let c1, let c2, let a): "C\(p(c1)) \(p(c2)) \(p(a))"
    case .close: "Z"
    }
  }.joined(separator: " ")
}

func flattened(_ segments: [Segment]) -> [CGPoint] {
  var points: [CGPoint] = []
  var current = CGPoint.zero
  for segment in segments {
    switch segment {
    case .move(let p), .line(let p):
      points.append(p)
      current = p
    case .quad(let c, let p):
      for step in 1...16 {
        let t = Double(step) / 16, u = 1 - t
        points.append(
          CGPoint(
            x: u * u * current.x + 2 * u * t * c.x + t * t * p.x, y: u * u * current.y + 2 * u * t * c.y + t * t * p.y))
      }
      current = p
    case .cubic(let c1, let c2, let p):
      for step in 1...16 {
        let t = Double(step) / 16, u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        points.append(
          CGPoint(x: a * current.x + b * c1.x + c * c2.x + d * p.x, y: a * current.y + b * c1.y + c * c2.y + d * p.y))
      }
      current = p
    case .close: break
    }
  }
  return points
}

func hullArea(_ points: [CGPoint]) -> Double {
  let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
  func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
    (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
  }
  var lower: [CGPoint] = [], upper: [CGPoint] = []
  for p in sorted {
    while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
    lower.append(p)
  }
  for p in sorted.reversed() {
    while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
    upper.append(p)
  }
  let hull = lower.dropLast() + upper.dropLast()
  guard hull.count >= 3 else { return 0 }
  return abs(zip(hull, hull.dropFirst() + [hull[0]]).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }) / 2
}

func swiftDraw(_ source: URL) throws -> String {
  let output = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).svg")
  defer { try? FileManager.default.removeItem(at: output) }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = ["swiftdraw", source.path, "--format", "sfsymbol", "--size", "medium", "--output", output.path]
  process.standardOutput = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    fatalError(
      "\(source.lastPathComponent): swiftdraw exited \(process.terminationStatus); install it with `brew install swiftdraw`"
    )
  }
  return try String(contentsOf: output, encoding: .utf8)
}

func marginX(_ template: String, _ side: String, _ weight: String) -> Double {
  let match = template.firstMatch(of: try! Regex("id=\"\(side)-margin-\(weight)\" d=\"M([0-9.]+),"))!
  return Double(match.output[1].substring!)!
}

func guideY(_ template: String, _ guide: String) -> Double {
  let match = template.firstMatch(of: try! Regex("id=\"\(guide)\" d=\"M[0-9.]+,([0-9.]+)"))!
  return Double(match.output[1].substring!)!
}

let overrides: [String: Overrides] = {
  guard let data = try? Data(contentsOf: sources.appending(path: "overrides.json")) else { return [:] }
  return try! JSONDecoder().decode([String: Overrides].self, from: data)
}()

// SwiftDraw only outlines a stroke when its fill is none, and never outlines <line> or <polyline>.
func validateStrokes(_ source: URL) throws {
  let svg = try String(contentsOf: source, encoding: .utf8)
  let rootFillsNone = svg.firstMatch(of: #/<svg\b[^>]*\bfill="none"/#) != nil
  if let tag = svg.firstMatch(of: #/<(line|polyline)\b/#) {
    fatalError("\(source.lastPathComponent): <\(tag.output.1)> is never outlined; rewrite it as a <path>")
  }
  for tag in svg.matches(of: #/<(?:path|circle|rect|ellipse|polygon|g)\b[^>]*>/#).map({ String($0.output) }) {
    guard let stroke = tag.firstMatch(of: #/\bstroke="([^"]*)"/#), stroke.output.1 != "none" else { continue }
    let fill = tag.firstMatch(of: #/\bfill="([^"]*)"/#)?.output.1
    if fill == "none" || (fill == nil && rootFillsNone) { continue }
    fatalError("\(source.lastPathComponent): stroked shape without fill=\"none\" is not outlined: \(tag)")
  }
}

// Build into a staging catalog and swap it in only once every symbol has succeeded.
let staging = try FileManager.default.url(
  for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: catalog.deletingLastPathComponent(), create: true
).appending(path: "Symbols.xcassets")
try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
try Data("{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n".utf8)
  .write(to: staging.appending(path: "Contents.json"))

let svgs = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
  .filter { $0.pathExtension == "svg" }
  .sorted { $0.lastPathComponent < $1.lastPathComponent }

struct Template {
  var svg: String
  var coverage: Double
  var capsHigh: Double
}

func margin(_ side: String, _ variant: String, x: Double, capline: Double) -> String {
  "        <path id=\"\(side)-margin-\(variant)\" d=\"M\(format(x)),\(format(capline - 20)) l0,110\" />"
}

func group(_ variant: String, _ paths: [String]) -> String {
  let body = paths.map { "            <path d=\"\($0)\" />" }.joined(separator: "\n")
  return "        <g id=\"\(variant)\">\n\(body)\n        </g>"
}

// A logo: SwiftDraw outlines it, and every weight gets the same regular drawing.
func logoTemplate(_ svg: URL, name: String) throws -> Template {
  try validateStrokes(svg)
  var template = try swiftDraw(svg)
  let regularGroup = template.firstMatch(of: #/<g id="Regular-M"[^>]*>([\s\S]*?)<\/g>/#)!.output.1
  let columns = weights.map { (marginX(template, "left", "\($0)-M") + marginX(template, "right", "\($0)-M")) / 2 }
  let paths = regularGroup.matches(of: #/<path d="([^"]+)"/#).map { parse(String($0.output.1)) }
  // A stroke SwiftDraw failed to outline anyway comes back as a zero-area open path.
  guard paths.allSatisfy({ hullArea(flattened($0)) > 0.01 }) else {
    fatalError("\(name): unoutlined stroke in SwiftDraw output; rewrite it as a <path>")
  }
  let bounds = paths.map { cgPath($0).boundingBoxOfPath }.reduce(CGRect.null) { $0.union($1) }
  let coverage = min(1, hullArea(paths.flatMap(flattened)) / (bounds.width * bounds.height))

  let capsTall = overrides[name]?.height ?? opticalHeight(coverage: coverage)
  let capsHigh = min(capsTall, maxWidth * bounds.height / bounds.width)
  var margins: [String] = []
  var groups: [String] = []
  for imageScale in imageScales {
    let capline = guideY(template, "Capline-\(imageScale.name)")
    let baseline = guideY(template, "Baseline-\(imageScale.name)")
    let capHeight = (baseline - capline) * imageScale.ratio
    let scale = capsHigh * capHeight / bounds.height
    let halfWidth = bounds.width * scale / 2
    let bearing = sideBearing(coverage: coverage) * capHeight
    let centerY = (capline + baseline) / 2
    for (weight, center) in zip(weights, columns) {
      let variant = "\(weight)-\(imageScale.name)"
      groups.append(
        group(
          variant,
          paths.map { segments in
            serialize(segments) { p in
              CGPoint(x: (p.x - bounds.midX) * scale + center, y: (p.y - bounds.midY) * scale + centerY)
            }
          }))
      margins.append(margin("left", variant, x: center - halfWidth - bearing, capline: capline))
      margins.append(margin("right", variant, x: center + halfWidth + bearing, capline: capline))
    }
  }
  template = template.replacing(#/\s*<path id="(left|right)-margin-[^"]+" d="[^"]*" \/>/#, with: "")
  template = template.replacing(#/(<path id="Baseline-L" d="[^"]*" \/>)/#) {
    "\($0.output.1)\n" + margins.joined(separator: "\n")
  }
  template = template.replacing(#/<g id="Symbols">[\s\S]*<\/svg>/#) { _ in
    "<g id=\"Symbols\">\n" + groups.joined(separator: "\n") + "\n    </g>\n</svg>\n"
  }
  return Template(svg: template, coverage: coverage, capsHigh: capsHigh)
}

// Line art: every weight and image scale stroked at SF Symbols' width, in a static template whose
// 27 variants Xcode uses as drawn. The centerlines keep one size and position at every weight, so
// heavier weights grow outward from them as SF Symbols do.
func lineArtTemplate(_ svg: URL, name: String) throws -> Template {
  let shapes = try lineArt(svg)
  let centerlines = shapes.reduce(CGRect.null) { $0.union($1.centerline.boundingBoxOfPath) }
  let rows = [("S", 76.0, 146.0), ("M", 276.0, 346.0), ("L", 476.0, 546.0)]
  let columns = lineArtWeights.indices.map { 250 + 200 * Double($0) }
  let width = columns.last! + 150

  // Size the regular medium glyph, centerlines plus stroke, like a logo of the same coverage.
  let regularStroke = lineArtStrokes["M"]![lineArtWeights.firstIndex(of: "Regular")!]
  func regular(capsHigh: Double) -> CGRect {
    let scale = (capsHigh - regularStroke) / centerlines.height
    let transform = CGAffineTransform(scaleX: scale, y: scale)
    let path = outline(shapes, transform: transform, width: regularStroke)
    return path.boundingBoxOfPath
  }
  let draft = outline(
    shapes, transform: CGAffineTransform(scaleX: 1 / centerlines.height, y: 1 / centerlines.height),
    width: regularStroke)
  let draftBounds = draft.boundingBoxOfPath
  let coverage = min(1, hullArea(flattened(segments(draft))) / (draftBounds.width * draftBounds.height))
  let capsTall = overrides[name]?.height ?? opticalHeight(coverage: coverage)
  let regularBounds = regular(capsHigh: capsTall)
  let capsHigh = min(capsTall, maxWidth * regularBounds.height / regularBounds.width)
  let capsPerUnit = (capsHigh - regularStroke) / centerlines.height

  var margins: [String] = []
  var groups: [String] = []
  for ((row, capline, baseline), imageScale) in zip(rows, imageScales) {
    let rowCap = baseline - capline
    let scale = capsPerUnit * rowCap * imageScale.ratio
    let bearing = sideBearing(coverage: coverage) * rowCap * imageScale.ratio
    for (index, (weight, center)) in zip(lineArtWeights, columns).enumerated() {
      let variant = "\(weight)-\(row)"
      let transform = CGAffineTransform(translationX: center, y: (capline + baseline) / 2)
        .scaledBy(x: scale, y: scale)
        .translatedBy(x: -centerlines.midX, y: -centerlines.midY)
      let path = outline(shapes, transform: transform, width: lineArtStrokes[row]![index] * rowCap)
      let bounds = path.boundingBoxOfPath
      groups.append(group(variant, [serialize(segments(path)) { $0 }]))
      margins.append(margin("left", variant, x: bounds.minX - bearing, capline: capline))
      margins.append(margin("right", variant, x: bounds.maxX + bearing, capline: capline))
    }
  }

  let labels = zip(lineArtWeights, columns).map { "            <text x=\"\(format($1))\" y=\"30\">\($0)</text>" }
  let guides = rows.flatMap { row, capline, baseline in
    [("Capline", capline), ("Baseline", baseline)].map {
      "        <path id=\"\($0)-\(row)\" d=\"M18,\(format($1)) l\(format(width - 36)),0\" />"
    }
  }
  let template = """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg height="600" width="\(format(width))" xmlns="http://www.w3.org/2000/svg">
        <g id="Notes" font-family="LucidaGrande, 'Lucida Grande', sans-serif" font-size="13">
            <rect fill="white" height="600" width="\(format(width))" x="0" y="0" />
            <text x="18" y="176">Small</text>
            <text x="18" y="376">Medium</text>
            <text x="18" y="576">Large</text>
            <g font-size="9" text-anchor="middle">
    \(labels.joined(separator: "\n"))
            </g>
            <text id="template-version" fill="#505050" font-size="9" text-anchor="end" x="\(format(width - 15))" y="575">Template v.3.0</text>
        </g>
        <g id="Guides" stroke="rgb(39, 170, 225)" stroke-width="0.5">
    \(guides.joined(separator: "\n"))
    \(margins.joined(separator: "\n"))
        </g>
        <g id="Symbols">
    \(groups.joined(separator: "\n"))
        </g>
    </svg>

    """
  return Template(svg: template, coverage: coverage, capsHigh: capsHigh)
}

for svg in svgs {
  let name = svg.deletingPathExtension().lastPathComponent
  let template = try overrides[name]?.lineArt == true ? lineArtTemplate(svg, name: name) : logoTemplate(svg, name: name)

  let symbolset = staging.appending(path: "\(name).symbolset")
  try FileManager.default.createDirectory(at: symbolset, withIntermediateDirectories: true)
  try Data(template.svg.utf8).write(to: symbolset.appending(path: "\(name).svg"))
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
  print(String(format: "%-34@ coverage %.2f  height %.2f cap", name as NSString, template.coverage, template.capsHigh))
}

if FileManager.default.fileExists(atPath: catalog.path) {
  _ = try FileManager.default.replaceItemAt(catalog, withItemAt: staging)
} else {
  try FileManager.default.moveItem(at: staging, to: catalog)
}
