import SwiftUI

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
