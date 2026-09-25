import SwiftUI

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

extension EnvironmentValues {
  /// Set on the copy of a row that flies out of the composer. The bubble
  /// tint is translucent, and in flight it crosses the composer and other
  /// rows; the copy paints it over the transcript's own backdrop so it
  /// reads as solid and still matches the landed bubble exactly.
  @Entry public var isTranscriptSendProxy = false
}

/// The user message bubble's fill. It carries a native marker view so a send
/// flight can find the bubble's exact frame inside a laid-out row.
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

  /// What the transcript draws behind its rows.
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

  /// Found by type inside a row host; never drawn.
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

  /// Found by type inside a row host; never drawn.
  public final class UserBubbleAnchorView: NSView {
    override public func hitTest(_: NSPoint) -> NSView? { nil }
  }
#endif
