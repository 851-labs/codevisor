import SwiftUI

struct SettingsListActions<Actions: View>: View {
  var message: String?
  @ViewBuilder let actions: () -> Actions

  init(message: String? = nil, @ViewBuilder actions: @escaping () -> Actions) {
    self.message = message
    self.actions = actions
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let message {
        Label(message, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 10) {
        Spacer(minLength: 0)
        actions()
      }
    }
    .font(.body)
  }
}
