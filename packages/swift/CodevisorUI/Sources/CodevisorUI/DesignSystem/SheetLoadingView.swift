import SwiftUI

public struct SheetLoadingView: View {
  @Environment(\.theme) private var theme
  private let title: String

  public init(_ title: String) {
    self.title = title
  }

  public var body: some View {
    ProgressView(title)
      .controlSize(.small)
      .tint(theme.isSystem ? nil : theme.accent)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
