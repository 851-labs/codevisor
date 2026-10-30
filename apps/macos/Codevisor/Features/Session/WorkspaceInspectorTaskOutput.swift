import SwiftUI

struct WorkspaceInspectorTaskOutput: View {
  private static let maxHeight: CGFloat = 220

  let lines: [String]
  @State private var contentHeight: CGFloat = 0

  var body: some View {
    ScrollView {
      Text(lines.joined(separator: "\n"))
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }
    .defaultScrollAnchor(.bottom)
    .defaultScrollAnchor(.bottom, for: .sizeChanges)
    .onScrollGeometryChange(for: CGFloat.self) {
      $0.contentSize.height
    } action: { _, height in
      contentHeight = height
    }
    .frame(height: min(contentHeight, Self.maxHeight))
    .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
  }
}
