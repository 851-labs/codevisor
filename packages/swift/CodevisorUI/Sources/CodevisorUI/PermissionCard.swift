#if os(macOS)
  import SwiftUI

  public struct PermissionCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
      self.content = content()
    }

    public var body: some View {
      VStack(spacing: 0) { content }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackgroundColor))
    }
  }
#endif
