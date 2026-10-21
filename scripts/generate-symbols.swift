#!/usr/bin/env swift
// Builds CodevisorUI's custom SF Symbols from packages/swift/CodevisorUI/Symbols/*.svg.
// SwiftDraw outlines strokes into a symbol template; this script then sizes and places each
// glyph with the metrics Apple's own symbols use, so logos match neighboring SF Symbols.
// Requires `brew install swiftdraw`. Run with `swift scripts/generate-symbols.swift`.
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sources = root.appending(path: "packages/swift/CodevisorUI/Symbols")
let catalog = root.appending(path: "packages/swift/CodevisorUI/Sources/CodevisorUI/Resources/Symbols.xcassets")

// Every weight is drawn at each image scale. A template missing a scale renders nothing at that
// scale (iOS list rows use .large), and one with only small variants renders about 1.28x too big.
let weights = ["Ultralight", "Regular", "Black"]
// Glyph size of each image scale relative to medium, measured from SF Symbols.
let imageScales: [(name: String, ratio: Double)] = [("S", 0.787), ("M", 1), ("L", 1.276)]

// Optical metrics measured from SF Symbols at regular weight, in cap heights. A square glyph is
// 1.27 tall with 0.176 side bearings; a circle, which covers less of its box, is 1.41 tall with
// 0.134 bearings. Coverage is the share of the bounding box inside the glyph's convex hull.
func opticalHeight(coverage: Double) -> Double { 1.27 + 0.65 * (1 - coverage) }
func sideBearing(coverage: Double) -> Double { max(0.09, 0.176 - 0.195 * (1 - coverage)) }
// Wide marks shrink to the widest everyday SF Symbols, such as `camera.fill` and `video.fill`.
let maxWidth = 1.69

// Per-symbol adjustments from Symbols/overrides.json. `height` pins the glyph height in cap
// heights, so a family drawn on one grid keeps its shared proportions. `outset` grows every edge
// by that fraction of the glyph height, thickening outlined line art to SF Symbols' regular weight.
struct Overrides: Decodable {
  var height: Double?
  var outset: Double?
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

func outset(_ paths: [[Segment]], by distance: Double) -> [[Segment]] {
  let shape = CGMutablePath()
  for path in paths { shape.addPath(cgPath(path)) }
  let edge = shape.copy(strokingWithWidth: distance * 2, lineCap: .round, lineJoin: .round, miterLimit: 4)
  return [segments(shape.union(edge))]
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
        points.append(CGPoint(x: u * u * current.x + 2 * u * t * c.x + t * t * p.x, y: u * u * current.y + 2 * u * t * c.y + t * t * p.y))
      }
      current = p
    case .cubic(let c1, let c2, let p):
      for step in 1...16 {
        let t = Double(step) / 16, u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        points.append(CGPoint(x: a * current.x + b * c1.x + c * c2.x + d * p.x, y: a * current.y + b * c1.y + c * c2.y + d * p.y))
      }
      current = p
    case .close: break
    }
  }
  return points
}

func hullArea(_ points: [CGPoint]) -> Double {
  let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
  func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
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
    fatalError("\(source.lastPathComponent): swiftdraw exited \(process.terminationStatus); install it with `brew install swiftdraw`")
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

for svg in svgs {
  let name = svg.deletingPathExtension().lastPathComponent
  try validateStrokes(svg)
  var template = try swiftDraw(svg)
  let regularGroup = template.firstMatch(of: #/<g id="Regular-M"[^>]*>([\s\S]*?)<\/g>/#)!.output.1
  let columns = weights.map { (marginX(template, "left", "\($0)-M") + marginX(template, "right", "\($0)-M")) / 2 }
  var paths = regularGroup.matches(of: #/<path d="([^"]+)"/#).map { parse(String($0.output.1)) }
  // A stroke SwiftDraw failed to outline anyway comes back as a zero-area open path.
  guard paths.allSatisfy({ hullArea(flattened($0)) > 0.01 }) else {
    fatalError("\(name): unoutlined stroke in SwiftDraw output; rewrite it as a <path>")
  }
  if let fraction = overrides[name]?.outset {
    let height = paths.map { cgPath($0).boundingBoxOfPath }.reduce(CGRect.null) { $0.union($1) }.height
    paths = outset(paths, by: fraction * height)
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
      let body = paths.map { segments in
        let d = serialize(segments) { p in
          CGPoint(x: (p.x - bounds.midX) * scale + center, y: (p.y - bounds.midY) * scale + centerY)
        }
        return "            <path d=\"\(d)\" />"
      }.joined(separator: "\n")
      groups.append("        <g id=\"\(variant)\">\n\(body)\n        </g>")
      for (side, x) in [("left", center - halfWidth - bearing), ("right", center + halfWidth + bearing)] {
        margins.append("        <path id=\"\(side)-margin-\(variant)\" d=\"M\(format(x)),\(format(capline - 20)) l0,110\" />")
      }
    }
  }
  template = template.replacing(#/\s*<path id="(left|right)-margin-[^"]+" d="[^"]*" \/>/#, with: "")
  template = template.replacing(#/(<path id="Baseline-L" d="[^"]*" \/>)/#) { "\($0.output.1)\n" + margins.joined(separator: "\n") }
  template = template.replacing(#/<g id="Symbols">[\s\S]*<\/svg>/#) { _ in
    "<g id=\"Symbols\">\n" + groups.joined(separator: "\n") + "\n    </g>\n</svg>\n"
  }

  let symbolset = staging.appending(path: "\(name).symbolset")
  try FileManager.default.createDirectory(at: symbolset, withIntermediateDirectories: true)
  try Data(template.utf8).write(to: symbolset.appending(path: "\(name).svg"))
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
  print(String(format: "%-34@ coverage %.2f  height %.2f cap", name as NSString, coverage, capsHigh))
}

if FileManager.default.fileExists(atPath: catalog.path) {
  _ = try FileManager.default.replaceItemAt(catalog, withItemAt: staging)
} else {
  try FileManager.default.moveItem(at: staging, to: catalog)
}
