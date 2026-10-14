import SwiftUI

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

extension EnvironmentValues {
  @Entry public var isTranscriptSendProxy = false
}

public struct UserBubbleBackground: View {
  public static let cornerRadius: CGFloat = 14

  private let color: Color
  @Environment(\.isTranscriptSendProxy) private var isProxy
  @Environment(\.theme) private var theme

  public init(color: Color) {
    self.color = color
  }

  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    shape
      .fill(color)
      .background { if isProxy { shape.fill(Self.transcriptBackdrop(for: theme)) } }
      .background { UserBubbleAnchor() }
  }

  public static func transcriptBackdrop(for theme: Theme) -> Color {
    guard theme.isSystem else { return theme.windowBackground }
    #if canImport(UIKit)
      return Color(uiColor: .systemGroupedBackground)
    #else
      return Color(nsColor: .windowBackgroundColor)
    #endif
  }
}

#if canImport(UIKit)
  private struct UserBubbleAnchor: UIViewRepresentable {
    func makeUIView(context _: Context) -> UserBubbleAnchorView { UserBubbleAnchorView() }
    func updateUIView(_: UserBubbleAnchorView, context _: Context) {}
  }

  public final class UserBubbleAnchorView: UIView {
    init() {
      super.init(frame: .zero)
      isUserInteractionEnabled = false
      accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }
  }
#else
  private struct UserBubbleAnchor: NSViewRepresentable {
    func makeNSView(context _: Context) -> UserBubbleAnchorView { UserBubbleAnchorView() }
    func updateNSView(_: UserBubbleAnchorView, context _: Context) {}
  }

  public final class UserBubbleAnchorView: NSView {
    override public func hitTest(_: NSPoint) -> NSView? { nil }
  }
#endif
