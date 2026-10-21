import CodevisorCore
import SwiftUI

struct ToolIconGlyph: View {
  let symbol: String

  @Environment(\.toolIconSide) private var side

  var body: some View {
    let size = ToolIconKind.symbol.size(in: side)
    image
      .font(.system(size: size, weight: ToolIconMetrics.symbolWeight))
      .symbolRenderingMode(.monochrome)
  }

  private var image: Image {
    if symbol == ToolCallIcon.codevisorMark {
      CodevisorSymbol.codevisorMark.image
    } else {
      Image(systemName: symbol)
    }
  }
}
