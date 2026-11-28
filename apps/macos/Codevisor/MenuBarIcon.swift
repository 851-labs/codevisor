import CodevisorUI
import SwiftUI

struct MenuBarIcon: View {
  private static let pointSize: CGFloat = 18

  var body: some View {
    mark.accessibilityLabel("Codevisor")
  }

  private var mark: Image {
    guard let sized = CodevisorSymbol.codevisorMark.nsImage(pointSize: Self.pointSize) else {
      return CodevisorSymbol.codevisorMark.image
    }
    return Image(nsImage: sized)
  }
}
