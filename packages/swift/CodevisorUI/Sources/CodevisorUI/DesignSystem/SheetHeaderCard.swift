import SwiftUI

public struct SheetHeaderCard<Icon: View>: View {
  private let title: String
  private let subtitle: String
  private let subtitleLineLimit: Int?
  private let isWorking: Bool
  private let icon: Icon

  public init(
    title: String,
    subtitle: String,
    subtitleLineLimit: Int? = 1,
    isWorking: Bool = false,
    @ViewBuilder icon: () -> Icon
  ) {
    self.title = title
    self.subtitle = subtitle
    self.subtitleLineLimit = subtitleLineLimit
    self.isWorking = isWorking
    self.icon = icon()
  }

  public var body: some View {
    HStack(spacing: 12) {
      icon.accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
          .lineLimit(1)
        Text(subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(subtitleLineLimit)
      }
      Spacer(minLength: 0)
      if isWorking {
        ProgressView().controlSize(.small)
      }
    }
    .padding(.vertical, 4)
  }
}
