import SwiftUI

public struct SettingsDeletionRow<Action: View>: View {
  private let title: String
  private let description: String
  private let action: Action

  public init(title: String, description: String, @ViewBuilder action: () -> Action) {
    self.title = title
    self.description = description
    self.action = action()
  }

  public var body: some View {
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
