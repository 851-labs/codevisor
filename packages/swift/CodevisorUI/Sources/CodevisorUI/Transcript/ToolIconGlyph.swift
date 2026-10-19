import CodevisorCore
import SwiftUI

struct ToolIconGlyph: View {
  let symbol: String

  @Environment(\.toolIconSide) private var side

  var body: some View {
    let size = ToolIconKind(symbol: symbol).size(in: side)
    if symbol == ToolCallIcon.codevisorMark {
      Image("CodevisorMark", bundle: .module)
        .renderingMode(.template)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
    } else {
      Image(systemName: symbol)
        .font(.system(size: size, weight: ToolIconMetrics.symbolWeight))
        .symbolRenderingMode(.monochrome)
    }
  }
}
