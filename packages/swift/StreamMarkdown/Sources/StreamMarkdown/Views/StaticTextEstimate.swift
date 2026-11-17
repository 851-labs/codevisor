import CoreGraphics

enum StaticTextEstimate {
  static func height(ofCode code: String) -> CGFloat {
    CGFloat(code.reduce(1) { $0 + ($1 == "\n" ? 1 : 0) }) * 17 + 20
  }
}
