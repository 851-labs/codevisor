import CodevisorClient
import CoreGraphics
import Foundation

/// Xcode's DeviceKit chrome for one screen: a nine-slice bezel drawn around the screen and the
/// hardware buttons on its edges, from the chrome bundle's chrome.json and PDFs (read on the
/// simulator's Mac and sent here).
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
    /// The bezel edge the button sits on: "left", "right", "top", "bottom".
    public var anchor: String
    /// Whether `offsets` count from the edge's start ("leading") or end ("trailing").
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

  /// Newer chromes (the iPhone Duo's) draw the bezel from one composite image rather than the
  /// nine slices, which are left as "unused" placeholders. These mark, per corner, the areas the
  /// composite keeps as they are while the rest stretches to the screen.
  public struct ResizeRect: Decodable, Sendable, Equatable {
    /// The corner the rect is measured from: "upperLeft", "upperRight", "lowerLeft", "lowerRight".
    public var type: String
    /// The rect's center, from that corner (negative when measured from the right or top).
    public var centerPoint: Point
    public var size: Size
  }

  public var identifier: String
  public var images: Images
  public var inputs: [Input]?
  public var paths: Paths?
  public var resizeRects: [ResizeRect]?

  /// The composite's fixed margins (left, right, top, bottom, in points) when the chrome is drawn
  /// from its composite: as far into the image as any corner's resize rect reaches.
  public var compositeCaps: (left: Double, right: Double, top: Double, bottom: Double)? {
    guard let rects = resizeRects, !rects.isEmpty, images.composite != nil else { return nil }
    func reach(_ corners: Set<String>, _ extent: (ResizeRect) -> Double) -> Double {
      rects.filter { corners.contains($0.type) }.map(extent).max() ?? 0
    }
    let horizontal = { (rect: ResizeRect) in abs(rect.centerPoint.x) + rect.size.width / 2 }
    let vertical = { (rect: ResizeRect) in abs(rect.centerPoint.y) + rect.size.height / 2 }
    return (
      reach(["upperLeft", "lowerLeft"], horizontal), reach(["upperRight", "lowerRight"], horizontal),
      reach(["upperLeft", "upperRight"], vertical), reach(["lowerLeft", "lowerRight"], vertical)
    )
  }

  public init(json: Data) throws {
    self = try JSONDecoder().decode(Self.self, from: json)
  }
}

/// Where everything goes for one screen size, in points, origin at the canvas's top-left.
public struct SimulatorChromeLayout: Equatable, Sendable {
  public struct Button: Equatable, Sendable, Identifiable {
    public var input: SimulatorChromeDefinition.Input
    public var frame: CGRect
    /// Where the button moves to while the pointer is over it.
    public var rolloverFrame: CGRect
    /// The artwork was drawn for the other kind of edge (the iPhone Duo's inner chrome reuses its
    /// cover's top-edge volume buttons on its side), so it's drawn a quarter turn counterclockwise
    /// to lie along this one; `frame` is already the turned size.
    public var turned = false
    public var id: String { input.name }
  }

  /// Everything drawn, bezel plus the buttons that stick out of it.
  public var canvas: CGSize
  /// The bezel's outer edge.
  public var frame: CGRect
  public var screen: CGRect
  public var buttons: [Button]
  public var outerCornerRadius: Double

  /// A bare screen (Apple TV, Vision Pro, or chrome that failed to load): a thin rounded border.
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

  /// Lays the chrome around a screen of `screenSize` points. `imageSize` gives each image's
  /// natural size (its PDF page) so buttons keep their drawn proportions.
  public init(
    definition: SimulatorChromeDefinition, screen screenSize: CGSize, imageSize: (String) -> CGSize?
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
        return Button(
          input: input, frame: Self.place(input, offset: input.offsets.normal, size: size, in: bezel),
          rolloverFrame: Self.place(
            input, offset: input.offsets.rollover ?? input.offsets.normal, size: size, in: bezel),
          turned: turned)
      } ?? []
    // Grow the canvas to whatever the buttons need, then move everything into it.
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

  /// Whether a button's artwork lies across its edge rather than along it: long side out from a
  /// side edge, or up from the top or bottom.
  static func isTurned(_ input: SimulatorChromeDefinition.Input, size: CGSize) -> Bool {
    switch input.anchor {
    case "top", "bottom": size.height > size.width
    default: size.width > size.height
    }
  }

  /// DeviceKit's placement: an offset from the anchored edge (inward positive on the left and
  /// top, negative on the right and bottom), the image hanging outside by the rest of its depth.
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

/// A PDF from a chrome bundle or a screen mask, drawn to a bitmap at the size it's shown.
/// `@unchecked`: a CGPDFDocument is immutable once opened and safe to draw from any thread.
public struct SimulatorPDFImage: @unchecked Sendable {
  private let document: CGPDFDocument

  public init?(base64: String) {
    guard let data = Data(base64Encoded: base64), let provider = CGDataProvider(data: data as CFData),
      let document = CGPDFDocument(provider), document.numberOfPages >= 1
    else { return nil }
    self.document = document
  }

  /// The page's size in points.
  public var size: CGSize {
    document.page(at: 1)?.getBoxRect(.mediaBox).size ?? .zero
  }

  /// The page stretched to `size` points at `scale` pixels per point.
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

/// A chrome bundle ready to draw: its definition and decoded PDFs.
public struct SimulatorChrome: Sendable {
  public let definition: SimulatorChromeDefinition
  public let images: [String: SimulatorPDFImage]

  public init(_ chrome: ServerSimulatorChrome) throws {
    definition = try SimulatorChromeDefinition(json: chrome.definition)
    images = chrome.images.compactMapValues { SimulatorPDFImage(base64: $0) }
  }

  public func layout(screen: CGSize) -> SimulatorChromeLayout {
    SimulatorChromeLayout(definition: definition, screen: screen) { images[$0]?.size }
  }
}
