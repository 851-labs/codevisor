import SwiftUI

struct SettingsDeletionRow<Action: View>: View {
  let title: String
  let description: String
  @ViewBuilder let action: Action

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
        Text(description)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      action
        .fixedSize()
    }
  }
}
