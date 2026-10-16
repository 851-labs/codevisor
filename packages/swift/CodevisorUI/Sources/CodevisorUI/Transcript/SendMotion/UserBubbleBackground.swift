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
  private let color: Color
  @Environment(\.isTranscriptSendProxy) private var isProxy
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  public init(color: Color) {
    self.color = color
  }

  public var body: some View {
    Self.shape(for: dynamicTypeSize)
      .fill(isProxy ? Color.clear : color)
      .background { UserBubbleAnchor() }
  }

  public static func shape(for dynamicTypeSize: DynamicTypeSize) -> RoundedRectangle {
    RoundedRectangle(cornerRadius: cornerRadius(for: dynamicTypeSize), style: .continuous)
  }

  public static func cornerRadius(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
    (bodyLineHeight(for: dynamicTypeSize) + TranscriptSendFlightGeometry.bubbleTextInsets.vertical * 2) / 2
  }

  #if canImport(UIKit)
    private static func bodyLineHeight(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
      let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
      return UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).lineHeight
    }
  #else
    private static func bodyLineHeight(for _: DynamicTypeSize) -> CGFloat {
      NSLayoutManager().defaultLineHeight(for: .preferredFont(forTextStyle: .body))
    }
  #endif

  public static func transcriptBackdrop() -> Color {
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
