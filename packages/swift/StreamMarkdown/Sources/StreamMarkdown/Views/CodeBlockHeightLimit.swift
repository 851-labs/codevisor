import SwiftUI

public struct CodeBlockHeightLimit<Content: View>: View {
  private let maxHeight: CGFloat?
  private let content: Content

  public init(maxHeight: CGFloat?, @ViewBuilder content: () -> Content) {
    self.maxHeight = maxHeight
    self.content = content()
  }

  public var body: some View {
    if let maxHeight {
      ScrollView(.vertical) { content }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      content
    }
  }
}
