import CoreGraphics
import ScreenSharingBench

public struct BenchTestCardLayout: Sendable, Equatable {
  private static let fiducialPoints = 32
  private static let insetPoints = 8
  private static let gapBelowBarcodePoints = 16

  public let fiducialSize: Int
  public let inset: Int
  public let top: Int

  public init(canvas: BenchSceneCanvas, barcodeHeight: Int) {
    fiducialSize = canvas.pixels(Self.fiducialPoints)
    inset = canvas.pixels(Self.insetPoints)
    top = barcodeHeight + canvas.pixels(Self.gapBelowBarcodePoints)
  }

  public static func geometry(of canvas: BenchSceneCanvas) -> BenchCardGeometry {
    let barcode = BenchBarcodeLayout.standard
    let layout = BenchTestCardLayout(canvas: canvas, barcodeHeight: barcode.height)
    let fiducials = layout.fiducialOrigins(canvas)
    let barcodeRect = BenchPixelRect(x: barcode.x, y: barcode.y, width: barcode.width, height: barcode.height)
    return BenchCardGeometry(
      canvasWidth: canvas.pixelWidth, canvasHeight: canvas.pixelHeight, fiducialSize: layout.fiducialSize,
      fiducialOrigins: fiducials,
      nonText: [barcodeRect] + fiducials.map { layout.square(at: $0) },
      chromaTiles: SceneChromaTiles.tiles(in: SceneCardArt.chromaAreas(canvas, top: layout.top).tiles).map(Self.inner))
  }

  private func fiducialOrigins(_ canvas: BenchSceneCanvas) -> [BenchPixelOffset] {
    let right = canvas.pixelWidth - fiducialSize - inset
    let bottom = canvas.pixelHeight - fiducialSize - inset
    return [
      BenchPixelOffset(dx: inset, dy: top), BenchPixelOffset(dx: right, dy: top),
      BenchPixelOffset(dx: inset, dy: bottom), BenchPixelOffset(dx: right, dy: bottom),
    ]
  }

  private func square(at origin: BenchPixelOffset) -> BenchPixelRect {
    BenchPixelRect(x: origin.dx, y: origin.dy, width: fiducialSize, height: fiducialSize)
  }

  private static func inner(_ rect: CGRect) -> BenchPixelRect {
    let left = Int(rect.minX.rounded(.up))
    let top = Int(rect.minY.rounded(.up))
    return BenchPixelRect(
      x: left, y: top, width: Int(rect.maxX.rounded(.down)) - left, height: Int(rect.maxY.rounded(.down)) - top)
  }
}
