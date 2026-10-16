import SwiftUI

public struct SheetLoadingView: View {
  private let title: String

  public init(_ title: String) {
    self.title = title
  }

  public var body: some View {
    ProgressView(title)
      .controlSize(.small)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
