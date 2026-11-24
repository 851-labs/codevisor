import SwiftUI

public struct MarkdownLinkMenuContent: View {
  private let items: [MarkdownLinkMenuItem]

  public init(_ items: [MarkdownLinkMenuItem]) {
    self.items = items
  }

  public var body: some View {
    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
      switch item {
      case let .action(title, systemImage, perform): Button(title, systemImage: systemImage, action: perform)
      case .separator: Divider()
      }
    }
  }
}
