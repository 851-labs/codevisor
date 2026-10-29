import SwiftUI

struct PluginCapabilityRow: View {
  let name: String
  let detail: String?
  var isApp = false
  @State private var isExpanded = false

  var body: some View {
    if let detail {
      Button {
        isExpanded.toggle()
      } label: {
        content(detail: detail)
      }
      .buttonStyle(.plain)
      .accessibilityHint(isExpanded ? "Shows less" : "Shows the full description")
    } else {
      content(detail: nil)
    }
  }

  private func content(detail: String?) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Text(name)
        if isApp {
          Text("App")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .background(.quaternary, in: Capsule())
        }
      }
      if let detail {
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(isExpanded ? nil : 2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}
