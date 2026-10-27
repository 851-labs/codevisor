import SwiftUI

struct PluginAppInlinePlaceholder: View {
  let systemImage: String
  let message: String
  var actionTitle = "Try Again"
  var action: (() -> Void)?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: systemImage)
      Text(message)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      if let action {
        Button(actionTitle, action: action)
          .buttonStyle(.borderless)
      }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
  }
}
