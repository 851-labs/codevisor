import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Job: Decodable {
  let input: String
  let output: String
  let width: Int
  let height: Int
  let device: Device
  let caption: String
}

enum Device: String, Decodable {
  case iphone
  case ipad
  case duoUnfolded = "duo-unfolded"

  var rim: CGFloat {
    switch self {
    case .iphone: 0.012
    case .ipad: 0.008
    case .duoUnfolded: 0.01
    }
  }

  var bezel: CGFloat {
    switch self {
    case .iphone: 0.022
    case .ipad: 0.04
    case .duoUnfolded: 0.022
    }
  }

  var screenRadius: CGFloat {
    switch self {
    case .iphone: 0.135
    case .ipad: 0.045
    case .duoUnfolded: 0.06
    }
  }

  var buttons: [Button] {
    switch self {
    case .iphone:
      [
        Button(edge: .left, start: 0.155, end: 0.19), Button(edge: .left, start: 0.24, end: 0.31),
        Button(edge: .left, start: 0.33, end: 0.4), Button(edge: .right, start: 0.27, end: 0.38),
        Button(edge: .right, start: 0.55, end: 0.62),
      ]
    case .ipad: [Button(edge: .top, start: 0.82, end: 0.9)]
    case .duoUnfolded: [Button(edge: .top, start: 0.78, end: 0.84), Button(edge: .top, start: 0.86, end: 0.92)]
    }
  }
}

struct Button {
  enum Edge { case left, right, top }
  let edge: Edge
  let start: CGFloat
  let end: CGFloat
}

let background = CGColor(srgbRed: 0.059, green: 0.059, blue: 0.063, alpha: 1)
let rimColors = [
  CGColor(srgbRed: 0.33, green: 0.33, blue: 0.35, alpha: 1), CGColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1),
  CGColor(srgbRed: 0.26, green: 0.26, blue: 0.28, alpha: 1),
]
let bezelColor = CGColor(srgbRed: 0.02, green: 0.02, blue: 0.02, alpha: 1)
let buttonColor = CGColor(srgbRed: 0.22, green: 0.22, blue: 0.235, alpha: 1)
let captionColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

func render(_ job: Job) throws {
  guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: job.input) as CFURL, nil),
    let screenshot = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: job.input]) }
  let canvas = CGSize(width: job.width, height: job.height)
  guard
    let context = CGContext(
      data: nil, width: job.width, height: job.height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
  else { throw CocoaError(.fileWriteUnknown) }
  context.interpolationQuality = .high
  context.setFillColor(background)
  context.fill(CGRect(origin: .zero, size: canvas))

  let portrait = canvas.height > canvas.width
  let margin = canvas.height * (portrait ? 0.035 : 0.045)
  let captionBottom = drawCaption(job.caption, in: context, canvas: canvas, portrait: portrait)
  let area = CGRect(x: 0, y: margin, width: canvas.width, height: captionBottom - margin * 2)
  drawDevice(job.device, screenshot: screenshot, in: context, area: area, maxWidth: canvas.width * 0.84)

  guard let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
      URL(fileURLWithPath: job.output) as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { throw CocoaError(.fileWriteUnknown) }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

func drawCaption(_ caption: String, in context: CGContext, canvas: CGSize, portrait: Bool) -> CGFloat {
  let size = portrait ? canvas.width * 0.068 : canvas.height * 0.06
  let font = CTFontCreateUIFontForLanguage(.system, size, nil)!
  var alignment = CTTextAlignment.center
  var lineHeight = size * 1.12
  let paragraph = withUnsafeBytes(of: &alignment) { alignmentBytes in
    withUnsafeBytes(of: &lineHeight) { heightBytes in
      let settings = [
        CTParagraphStyleSetting(
          spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: alignmentBytes.baseAddress!),
        CTParagraphStyleSetting(
          spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: heightBytes.baseAddress!),
        CTParagraphStyleSetting(
          spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: heightBytes.baseAddress!),
      ]
      return CTParagraphStyleCreate(settings, settings.count)
    }
  }
  let attributes: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): captionColor,
    NSAttributedString.Key(kCTKernAttributeName as String): -size * 0.012,
    NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
  ]
  let text = NSAttributedString(string: caption, attributes: attributes)
  let setter = CTFramesetterCreateWithAttributedString(text)
  let width = canvas.width * 0.88
  let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
    setter, CFRange(location: 0, length: 0), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
  let top = canvas.height * (portrait ? 0.07 : 0.075)
  let block = max(ceil(fitted.height), ceil(lineHeight * (portrait ? 2 : 1)))
  let blockBottom = canvas.height - top - block
  let rect = CGRect(
    x: (canvas.width - width) / 2, y: blockBottom + (block - ceil(fitted.height)) / 2, width: width,
    height: ceil(fitted.height))
  CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil), context)
  return blockBottom
}

func drawDevice(_ device: Device, screenshot: CGImage, in context: CGContext, area: CGRect, maxWidth: CGFloat) {
  let image = CGSize(width: screenshot.width, height: screenshot.height)
  let short = min(image.width, image.height)
  let edge = (device.rim + device.bezel) * short
  let scale = min(
    area.height / (image.height + edge * 2), min(area.width, maxWidth) / (image.width + edge * 2))
  let unit = short * scale
  let screenSize = CGSize(width: image.width * scale, height: image.height * scale)
  let rim = device.rim * unit
  let bezel = device.bezel * unit
  let outerSize = CGSize(
    width: screenSize.width + (rim + bezel) * 2, height: screenSize.height + (rim + bezel) * 2)
  let outer = CGRect(
    x: area.midX - outerSize.width / 2, y: area.midY - outerSize.height / 2, width: outerSize.width,
    height: outerSize.height)
  let screenRadius = device.screenRadius * unit
  let outerRadius = screenRadius + rim + bezel

  drawButtons(device.buttons, around: outer, depth: unit * 0.007, in: context)
  let rimPath = CGPath(roundedRect: outer, cornerWidth: outerRadius, cornerHeight: outerRadius, transform: nil)
  context.saveGState()
  context.addPath(rimPath)
  context.clip()
  let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: rimColors as CFArray, locations: [0, 0.5, 1])!
  context.drawLinearGradient(
    gradient, start: CGPoint(x: outer.minX, y: outer.maxY), end: CGPoint(x: outer.maxX, y: outer.minY), options: [])
  context.restoreGState()

  let body = outer.insetBy(dx: rim, dy: rim)
  let bodyRadius = screenRadius + bezel
  context.addPath(CGPath(roundedRect: body, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil))
  context.setFillColor(bezelColor)
  context.fillPath()

  let screen = body.insetBy(dx: bezel, dy: bezel)
  context.saveGState()
  context.addPath(CGPath(roundedRect: screen, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil))
  context.clip()
  context.draw(screenshot, in: screen)
  context.restoreGState()

  context.setFillColor(bezelColor)
  switch device {
  case .iphone:
    let island = CGSize(width: screen.width * 0.31, height: screen.width * 0.093)
    let rect = CGRect(
      x: screen.midX - island.width / 2, y: screen.maxY - screen.width * 0.03 - island.height, width: island.width,
      height: island.height)
    context.addPath(
      CGPath(roundedRect: rect, cornerWidth: island.height / 2, cornerHeight: island.height / 2, transform: nil))
    context.fillPath()
  case .duoUnfolded:
    let mark = CGSize(width: unit * 0.006, height: rim + bezel * 0.4)
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6))
    context.fill(CGRect(x: outer.midX - mark.width / 2, y: outer.maxY - mark.height, width: mark.width, height: mark.height))
    context.fill(CGRect(x: outer.midX - mark.width / 2, y: outer.minY, width: mark.width, height: mark.height))
  case .ipad:
    break
  }
}

func drawButtons(_ buttons: [Button], around outer: CGRect, depth: CGFloat, in context: CGContext) {
  context.setFillColor(buttonColor)
  for button in buttons {
    let rect: CGRect
    switch button.edge {
    case .left:
      rect = CGRect(
        x: outer.minX - depth, y: outer.maxY - outer.height * button.end, width: depth * 2,
        height: outer.height * (button.end - button.start))
    case .right:
      rect = CGRect(
        x: outer.maxX - depth, y: outer.maxY - outer.height * button.end, width: depth * 2,
        height: outer.height * (button.end - button.start))
    case .top:
      rect = CGRect(
        x: outer.minX + outer.width * button.start, y: outer.maxY - depth, width: outer.width * (button.end - button.start),
        height: depth * 2)
    }
    context.addPath(CGPath(roundedRect: rect, cornerWidth: depth, cornerHeight: depth, transform: nil))
    context.fillPath()
  }
}

do {
  let jobs = try JSONDecoder().decode([Job].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
  for job in jobs { try render(job) }
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
