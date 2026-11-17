import SwiftUI

struct SettingsNavigationRow<Detail: View>: View {
  let title: String
  let systemImage: String
  let action: () -> Void
  @ViewBuilder let detail: Detail

  var body: some View {
    Button(action: action) {
      HStack {
        Label(title, systemImage: systemImage)
        Spacer()
        detail
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .foregroundStyle(.primary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

extension SettingsNavigationRow where Detail == EmptyView {
  init(_ title: String, systemImage: String, action: @escaping () -> Void) {
    self.init(title: title, systemImage: systemImage, action: action) { EmptyView() }
  }
}
