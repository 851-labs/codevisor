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

  static func symbol(posture: String) -> String {
    switch posture.lowercased() {
    case "closed": "iphone"
    case "book": "book"
    case "open", "flat": "rectangle.portrait.split.2x1"
    case "tent": "triangle"
    default: "circle"
    }
  }
}
