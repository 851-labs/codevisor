import SwiftUI

/// The brand glyph for a harness — the same bundled lobe-icons set the macOS
/// harness picker uses (template-rendered, so it follows the label color) —
/// falling back to an SF Symbol for harnesses without a bundled icon.
struct HarnessIconView: View {
  let harnessId: String
  var fallbackSymbolName: String = "cpu"
  var size: CGFloat = 16

  private var assetName: String { "harness-\(harnessId)" }

  var body: some View {
    if UIImage(named: assetName) != nil {
      Image(assetName)
        .resizable()
        .renderingMode(.template)
        .scaledToFit()
        .frame(width: size, height: size)
    } else {
      Image(systemName: fallbackSymbolName)
        .font(.system(size: size - 2, weight: .medium))
    }
  }
}
