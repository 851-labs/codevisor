import SwiftUI

public struct HarnessGlyph: View {
  let harnessId: String?
  let fallbackSymbolName: String
  let size: CGFloat?

  public init(harnessId: String?, fallbackSymbolName: String = "sparkle", size: CGFloat? = nil) {
    self.harnessId = harnessId
    self.fallbackSymbolName = fallbackSymbolName
    self.size = size
  }

  public var body: some View {
    let image = CodevisorSymbol.harness(harnessId, fallback: fallbackSymbolName)
    if let size {
      image.font(.system(size: size))
    } else {
      image
    }
  }
}
