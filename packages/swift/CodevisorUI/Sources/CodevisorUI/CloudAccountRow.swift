import SwiftUI

struct CloudAccountRow<Actions: View>: View {
  let subtitle: String
  @ViewBuilder let actions: Actions

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      actions
    }
    .padding(.vertical, 4)
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "person.crop.circle.fill")
        .font(.system(size: 40))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text("Codevisor Account").font(.headline)
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
    }
  }
}

extension CloudAccountRow where Actions == EmptyView {
  init(subtitle: String) {
    self.init(subtitle: subtitle) { EmptyView() }
  }
}
