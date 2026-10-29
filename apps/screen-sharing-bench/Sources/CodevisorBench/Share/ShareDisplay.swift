import CoreGraphics

struct ShareDisplay: Encodable {
  let id: UInt32
  let points: String
  let pixels: String

  init(_ id: CGDirectDisplayID) {
    let mode = CGDisplayCopyDisplayMode(id)
    self.id = id
    points = mode.map { "\($0.width)x\($0.height)" } ?? "unknown"
    pixels = mode.map { "\($0.pixelWidth)x\($0.pixelHeight)" } ?? "unknown"
  }
}
