import CodevisorClient
import CoreGraphics
import Foundation
import ScreenSharing

/// Bitmaps the device canvas draws: the bezel composed from its nine slices, and the screen's
/// mask turned as the device is held. Rendered off the main actor.
enum SimulatorArtwork {
  /// The bezel's nine slices composed around the screen, at `scale` pixels per point. The
  /// slices are opaque inward (the screen covers them), so corners keep their natural size and
  /// the edges stretch between them.
  static func bezel(chrome: SimulatorChrome, layout: SimulatorChromeLayout, scale: CGFloat) -> CGImage? {
    let images = chrome.definition.images
    let width = Int((layout.canvas.width * scale).rounded(.up))
    let height = Int((layout.canvas.height * scale).rounded(.up))
    guard width > 0, height > 0, width * height <= 48_000_000,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // Top-left origin, in points.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    let frame = layout.frame
    func size(_ name: String?) -> CGSize { name.flatMap { chrome.images[$0]?.size } ?? .zero }
    func draw(_ name: String?, _ rect: CGRect) {
      guard let name, let image = chrome.images[name], rect.width > 0, rect.height > 0,
        let bitmap = image.render(size: rect.size, scale: scale)
      else { return }
      context.saveGState()
      // CGContext draws images bottom-up; flip locally so the slice isn't upside down.
      context.translateBy(x: rect.minX, y: rect.maxY)
      context.scaleBy(x: 1, y: -1)
      context.draw(bitmap, in: CGRect(origin: .zero, size: rect.size))
      context.restoreGState()
    }
    if let caps = chrome.definition.compositeCaps, let name = images.composite, let composite = chrome.images[name] {
      drawComposite(composite, caps: caps, in: frame, scale: scale, context: context)
      return context.makeImage()
    }
    let topLeft = size(images.topLeft), topRight = size(images.topRight)
    let bottomLeft = size(images.bottomLeft), bottomRight = size(images.bottomRight)
    draw(images.topLeft, CGRect(origin: frame.origin, size: topLeft))
    draw(
      images.topRight,
      CGRect(x: frame.maxX - topRight.width, y: frame.minY, width: topRight.width, height: topRight.height))
    draw(
      images.bottomLeft,
      CGRect(x: frame.minX, y: frame.maxY - bottomLeft.height, width: bottomLeft.width, height: bottomLeft.height))
    draw(
      images.bottomRight,
      CGRect(
        x: frame.maxX - bottomRight.width, y: frame.maxY - bottomRight.height, width: bottomRight.width,
        height: bottomRight.height))
    draw(
      images.top,
      CGRect(
        x: frame.minX + topLeft.width, y: frame.minY, width: frame.width - topLeft.width - topRight.width,
        height: size(images.top).height))
    draw(
      images.bottom,
      CGRect(
        x: frame.minX + bottomLeft.width, y: frame.maxY - size(images.bottom).height,
        width: frame.width - bottomLeft.width - bottomRight.width, height: size(images.bottom).height))
    draw(
      images.left,
      CGRect(
        x: frame.minX, y: frame.minY + topLeft.height, width: size(images.left).width,
        height: frame.height - topLeft.height - bottomLeft.height))
    draw(
      images.right,
      CGRect(
        x: frame.maxX - size(images.right).width, y: frame.minY + topRight.height, width: size(images.right).width,
        height: frame.height - topRight.height - bottomRight.height))
    return context.makeImage()
  }

  /// A composite bezel as a nine-slice: corners as drawn, edges stretched along them, the middle
  /// stretched both ways, so it fits a frame of any size (the Duo's inner screen is larger than its
  /// composite). Points throughout, in a context already flipped to a top-left origin.
  private static func drawComposite(
    _ composite: SimulatorPDFImage, caps: (left: Double, right: Double, top: Double, bottom: Double),
    in frame: CGRect, scale: CGFloat, context: CGContext
  ) {
    let source = composite.size
    guard source.width > 0, source.height > 0, let bitmap = composite.render(size: source, scale: scale) else { return }
    // Caps can't exceed half of either the image or the frame.
    let left = min(caps.left, source.width / 2, frame.width / 2)
    let right = min(caps.right, source.width / 2, frame.width / 2)
    let top = min(caps.top, source.height / 2, frame.height / 2)
    let bottom = min(caps.bottom, source.height / 2, frame.height / 2)
    let sourceColumns = [0, left, source.width - right, source.width]
    let sourceRows = [0, top, source.height - bottom, source.height]
    let targetColumns = [frame.minX, frame.minX + left, frame.maxX - right, frame.maxX]
    let targetRows = [frame.minY, frame.minY + top, frame.maxY - bottom, frame.maxY]
    let pixels = CGFloat(bitmap.width) / source.width
    for row in 0..<3 {
      for column in 0..<3 {
        // The middle row and column stretch from a plain strip a quarter of the way along: a
        // foldable's composite marks the hinge at the middle of its edges, which the open device,
        // drawn as one piece, doesn't show.
        let across = Self.plainSpan(sourceColumns, column)
        let down = Self.plainSpan(sourceRows, row)
        let from = CGRect(
          x: across.start * pixels, y: down.start * pixels, width: across.length * pixels,
          height: down.length * pixels
        ).integral
        let to = CGRect(
          x: targetColumns[column], y: targetRows[row], width: targetColumns[column + 1] - targetColumns[column],
          height: targetRows[row + 1] - targetRows[row])
        guard from.width > 0, from.height > 0, to.width > 0, to.height > 0, let piece = bitmap.cropping(to: from)
        else { continue }
        context.saveGState()
        // CGContext draws images bottom-up; flip locally so the piece isn't upside down.
        context.translateBy(x: to.minX, y: to.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(piece, in: CGRect(origin: .zero, size: to.size))
        context.restoreGState()
      }
    }
  }

  /// Where slice `index` of a nine-slice is taken from along one axis: the caps as they are, the
  /// middle as one point of it a quarter of the way along, stretched.
  static func plainSpan(_ edges: [Double], _ index: Int) -> (start: Double, length: Double) {
    guard index == 1 else { return (edges[index], edges[index + 1] - edges[index]) }
    let length = edges[2] - edges[1]
    return (edges[1] + length / 4, min(1, length))
  }

  /// Where `image` is opaque, in its pixels: across its middle row and down its middle column, so
  /// the device's outline and not the buttons around it (drawn separately) or a transparent margin.
  static func opaqueBounds(_ image: CGImage) -> CGRect? {
    let width = image.width, height = image.height
    guard width > 2, height > 2,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let data = context.data
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    // A bitmap context's first row in memory is the image's top.
    func opaque(_ x: Int, _ y: Int) -> Bool { pixels[(y * width + x) * 4 + 3] > 127 }
    let row = height / 2, column = width / 2
    guard let left = (0..<width).first(where: { opaque($0, row) }),
      let right = (0..<width).last(where: { opaque($0, row) }),
      let top = (0..<height).first(where: { opaque(column, $0) }),
      let bottom = (0..<height).last(where: { opaque(column, $0) })
    else { return nil }
    return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
  }

  /// The screen's alpha mask at `pixels` (native orientation), turned clockwise by `quarterTurns`.
  /// Without a mask PDF the screen's corner radii shape it.
  static func mask(display: ServerSimulatorDisplay, pixels: CGSize, quarterTurns: Int) -> CGImage? {
    let native = CGSize(width: max(1, pixels.width.rounded()), height: max(1, pixels.height.rounded()))
    let turned = quarterTurns % 2 == 0 ? native : CGSize(width: native.height, height: native.width)
    guard
      let context = CGContext(
        data: nil, width: Int(turned.width), height: Int(turned.height), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // Turn the context so drawing in native coordinates lands upright for the held device.
    context.translateBy(x: turned.width / 2, y: turned.height / 2)
    context.rotate(by: -CGFloat(quarterTurns % 4) * .pi / 2)
    context.translateBy(x: -native.width / 2, y: -native.height / 2)
    if let base64 = display.mask, let pdf = SimulatorPDFImage(base64: base64),
      let image = pdf.render(size: native, scale: 1)
    {
      context.draw(image, in: CGRect(origin: .zero, size: native))
    } else {
      let pointScale = native.width / max(1, display.width / max(1, display.scale))
      let radius = (display.cornerRadii.max() ?? 0) * pointScale
      context.setFillColor(CGColor(gray: 0, alpha: 1))
      context.addPath(
        CGPath(
          roundedRect: CGRect(origin: .zero, size: native), cornerWidth: min(radius, native.width / 2),
          cornerHeight: min(radius, native.height / 2), transform: nil))
      context.fillPath()
    }
    return context.makeImage()
  }

  /// `image` turned clockwise by quarter turns.
  static func turned(_ image: CGImage, quarterTurns: Int) -> CGImage {
    let turns = ((quarterTurns % 4) + 4) % 4
    guard turns != 0 else { return image }
    let size =
      turns % 2 == 0
      ? CGSize(width: image.width, height: image.height) : CGSize(width: image.height, height: image.width)
    guard
      let context = CGContext(
        data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
        space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
    else { return image }
    context.translateBy(x: size.width / 2, y: size.height / 2)
    context.rotate(by: -CGFloat(turns) * .pi / 2)
    context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
    return context.makeImage() ?? image
  }

  static func symbol(family: String) -> String {
    switch family {
    case "iPad": "ipad"
    case "Apple Watch": "applewatch"
    case "Apple TV": "appletv"
    case "Apple Vision": "vision.pro"
    default: "iphone"
    }
  }
}
