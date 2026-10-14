import CodevisorClient
import CoreGraphics
import Foundation

public struct SimulatorChromeDefinition: Decodable, Sendable, Equatable {
  public struct Images: Decodable, Sendable, Equatable {
    public var topLeft: String?
    public var top: String?
    public var topRight: String?
    public var right: String?
    public var bottomRight: String?
    public var bottom: String?
    public var bottomLeft: String?
    public var left: String?
    public var composite: String?
    public var sizing: Insets?
    public var padding: Size?
  }

  public struct Insets: Decodable, Sendable, Equatable {
    public var leftWidth: Double
    public var rightWidth: Double
    public var topHeight: Double
    public var bottomHeight: Double
  }

  public struct Size: Decodable, Sendable, Equatable {
    public var width: Double
    public var height: Double
  }

  public struct Point: Decodable, Sendable, Equatable {
    public var x: Double
    public var y: Double
  }

  public struct Input: Decodable, Sendable, Equatable, Identifiable {
    public struct Offsets: Decodable, Sendable, Equatable {
      public var normal: Point
      public var rollover: Point?
    }

    public var name: String
    public var accessibilityTitle: String?
    public var type: String?
    public var usagePage: Int?
    public var usage: Int?
    public var image: String?
    public var imageDown: String?
    public var onTop: Bool?
    public var anchor: String
    public var align: String?
    public var offsets: Offsets
    public var id: String { name }
  }

  public struct Paths: Decodable, Sendable, Equatable {
    public struct Border: Decodable, Sendable, Equatable {
      public var cornerRadiusX: Double?
    }
    public var simpleOutsideBorder: Border?
  }

  public struct ResizeRect: Decodable, Sendable, Equatable {
    public var type: String
    public var centerPoint: Point
    public var size: Size
  }

  public var identifier: String
  public var images: Images
  public var inputs: [Input]?
  public var paths: Paths?
  public var resizeRects: [ResizeRect]?

  public var compositeCaps: (left: Double, right: Double, top: Double, bottom: Double)? {
    guard let rects = resizeRects, !rects.isEmpty, images.composite != nil else { return nil }
    let corner = (paths?.simpleOutsideBorder?.cornerRadiusX ?? 0) * 1.6
    let radius = (x: corner, y: corner)
    func reach(_ corners: Set<String>, _ extent: (ResizeRect) -> Double) -> Double {
      rects.filter { corners.contains($0.type) }.map(extent).max() ?? 0
    }
    let horizontal = { (rect: ResizeRect) in abs(rect.centerPoint.x) + rect.size.width / 2 }
    let vertical = { (rect: ResizeRect) in abs(rect.centerPoint.y) + rect.size.height / 2 }
    return (
      max(radius.x, reach(["upperLeft", "lowerLeft"], horizontal)),
      max(radius.x, reach(["upperRight", "lowerRight"], horizontal)),
      max(radius.y, reach(["upperLeft", "upperRight"], vertical)),
      max(radius.y, reach(["lowerLeft", "lowerRight"], vertical))
    )
  }

  public init(json: Data) throws {
    self = try JSONDecoder().decode(Self.self, from: json)
  }
}

public struct SimulatorChromeLayout: Equatable, Sendable {
  public struct Button: Equatable, Sendable, Identifiable {
    public var input: SimulatorChromeDefinition.Input
    public var frame: CGRect
    public var rolloverFrame: CGRect
    public var turned = false
    public var id: String { input.name }
  }

  public var canvas: CGSize
  public var frame: CGRect
  public var screen: CGRect
  public var buttons: [Button]
  public var outerCornerRadius: Double

  public static func bare(screen size: CGSize, cornerRadius: Double) -> Self {
    let inset = 6.0
    let frame = CGRect(origin: .zero, size: CGSize(width: size.width + inset * 2, height: size.height + inset * 2))
    return .init(
      canvas: frame.size, frame: frame, screen: frame.insetBy(dx: inset, dy: inset), buttons: [],
      outerCornerRadius: cornerRadius + inset)
  }

  public init(canvas: CGSize, frame: CGRect, screen: CGRect, buttons: [Button], outerCornerRadius: Double) {
    self.canvas = canvas; self.frame = frame; self.screen = screen
    self.buttons = buttons; self.outerCornerRadius = outerCornerRadius
  }

  public struct Margins: Sendable, Equatable {
    public var left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat
    public static let zero = Margins(left: 0, top: 0, right: 0, bottom: 0)

    public init(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) {
      (self.left, self.top, self.right, self.bottom) = (left, top, right, bottom)
    }
  }

  static let buttonReach: CGFloat = 3

  public init(
    definition: SimulatorChromeDefinition, screen screenSize: CGSize, margins: Margins = .zero,
    imageSize: (String) -> CGSize?
  ) {
    let sizing = definition.images.sizing ?? .init(leftWidth: 18, rightWidth: 18, topHeight: 18, bottomHeight: 18)
    var bezel = CGRect(
      x: 0, y: 0, width: screenSize.width + sizing.leftWidth + sizing.rightWidth,
      height: screenSize.height + sizing.topHeight + sizing.bottomHeight)
    var buttons: [Button] =
      definition.inputs?.compactMap { input in
        guard let name = input.image, var size = imageSize(name) else { return nil }
        let turned = Self.isTurned(input, size: size)
        if turned { size = CGSize(width: size.height, height: size.width) }
        let device = CGRect(
          x: bezel.minX + margins.left, y: bezel.minY + margins.top,
          width: bezel.width - margins.left - margins.right, height: bezel.height - margins.top - margins.bottom)
        let frame = Self.place(input, offset: input.offsets.normal, size: size, in: device)
        let inward = Self.inward(input, frame: frame, device: device)
        return Button(
          input: input, frame: frame.offsetBy(dx: inward.x, dy: inward.y),
          rolloverFrame: Self.place(
            input, offset: input.offsets.rollover ?? input.offsets.normal, size: size, in: device
          ).offsetBy(dx: inward.x, dy: inward.y),
          turned: turned)
      } ?? []
    let union = buttons.reduce(bezel) { $0.union($1.rolloverFrame).union($1.frame) }
    let shift = CGPoint(x: -union.minX, y: -union.minY)
    bezel = bezel.offsetBy(dx: shift.x, dy: shift.y)
    for index in buttons.indices {
      buttons[index].frame = buttons[index].frame.offsetBy(dx: shift.x, dy: shift.y)
      buttons[index].rolloverFrame = buttons[index].rolloverFrame.offsetBy(dx: shift.x, dy: shift.y)
    }
    self.init(
      canvas: union.size, frame: bezel,
      screen: CGRect(
        x: bezel.minX + sizing.leftWidth, y: bezel.minY + sizing.topHeight, width: screenSize.width,
        height: screenSize.height),
      buttons: buttons,
      outerCornerRadius: definition.paths?.simpleOutsideBorder?.cornerRadiusX ?? 60)
  }

  static func isTurned(_ input: SimulatorChromeDefinition.Input, size: CGSize) -> Bool {
    switch input.anchor {
    case "top", "bottom": size.height > size.width
    default: size.width > size.height
    }
  }

  static func inward(_ input: SimulatorChromeDefinition.Input, frame: CGRect, device: CGRect) -> CGPoint {
    switch input.anchor {
    case "top": CGPoint(x: 0, y: max(0, device.minY - frame.minY - buttonReach))
    case "bottom": CGPoint(x: 0, y: -max(0, frame.maxY - device.maxY - buttonReach))
    case "right": CGPoint(x: -max(0, frame.maxX - device.maxX - buttonReach), y: 0)
    default: CGPoint(x: max(0, device.minX - frame.minX - buttonReach), y: 0)
    }
  }

  static func place(
    _ input: SimulatorChromeDefinition.Input, offset: SimulatorChromeDefinition.Point, size: CGSize, in bezel: CGRect
  ) -> CGRect {
    let trailing = input.align == "trailing"
    switch input.anchor {
    case "right":
      let y = trailing ? bezel.maxY + offset.y - size.height : bezel.minY + offset.y
      return CGRect(x: bezel.maxX + offset.x, y: y, width: size.width, height: size.height)
    case "top":
      let x = trailing ? bezel.maxX + offset.x - size.width : bezel.minX + offset.x
      return CGRect(x: x, y: bezel.minY + offset.y - size.height, width: size.width, height: size.height)
    case "bottom":
      let x = trailing ? bezel.maxX + offset.x - size.width : bezel.minX + offset.x
      return CGRect(x: x, y: bezel.maxY + offset.y, width: size.width, height: size.height)
    default:
      let y = trailing ? bezel.maxY + offset.y - size.height : bezel.minY + offset.y
      return CGRect(x: bezel.minX + offset.x - size.width, y: y, width: size.width, height: size.height)
    }
  }
}

public struct SimulatorPDFImage: @unchecked Sendable {
  private let document: CGPDFDocument

  public init?(base64: String) {
    guard let data = Data(base64Encoded: base64), let provider = CGDataProvider(data: data as CFData),
      let document = CGPDFDocument(provider), document.numberOfPages >= 1
    else { return nil }
    self.document = document
  }

  public var size: CGSize {
    document.page(at: 1)?.getBoxRect(.mediaBox).size ?? .zero
  }

  public func render(size: CGSize, scale: CGFloat) -> CGImage? {
    guard let page = document.page(at: 1) else { return nil }
    let width = max(1, Int((size.width * scale).rounded(.up)))
    let height = max(1, Int((size.height * scale).rounded(.up)))
    guard width * height <= 64_000_000,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let box = page.getBoxRect(.mediaBox)
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
    context.translateBy(x: -box.minX, y: -box.minY)
    context.drawPDFPage(page)
    return context.makeImage()
  }
}

public struct SimulatorChrome: Sendable {
  public let definition: SimulatorChromeDefinition
  public let images: [String: SimulatorPDFImage]

  public let margins: SimulatorChromeLayout.Margins

  public init(_ chrome: ServerSimulatorChrome) throws {
    definition = try SimulatorChromeDefinition(json: chrome.definition)
    let images = chrome.images.compactMapValues { SimulatorPDFImage(base64: $0) }
    self.images = images
    margins = Self.margins(of: definition.images.composite.flatMap { images[$0] })
  }

  public func layout(screen: CGSize) -> SimulatorChromeLayout {
    SimulatorChromeLayout(definition: definition, screen: screen, margins: margins) { images[$0]?.size }
  }

  private static func margins(of composite: SimulatorPDFImage?) -> SimulatorChromeLayout.Margins {
    guard let composite, let image = composite.render(size: composite.size, scale: 2),
      let opaque = SimulatorArtwork.opaqueBounds(image)
    else { return .zero }
    let scale = CGFloat(image.width) / max(1, composite.size.width)
    return .init(
      left: opaque.minX / scale, top: opaque.minY / scale, right: (CGFloat(image.width) - opaque.maxX) / scale,
      bottom: (CGFloat(image.height) - opaque.maxY) / scale)
  }
}
