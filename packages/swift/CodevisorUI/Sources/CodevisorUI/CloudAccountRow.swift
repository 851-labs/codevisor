import SwiftUI

struct CloudAccountRow<Trailing: View>: View {
  let subtitle: String
  @ViewBuilder let trailing: Trailing

  var body: some View {
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
      Spacer(minLength: 8)
      trailing
    }
    .padding(.vertical, 4)
  }
}

extension CloudAccountRow where Trailing == EmptyView {
  init(subtitle: String) {
    self.init(subtitle: subtitle) { EmptyView() }
  }
}
