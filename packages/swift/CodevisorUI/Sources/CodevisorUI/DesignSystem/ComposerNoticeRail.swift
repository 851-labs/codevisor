import SwiftUI

public struct ComposerNoticeRail: View {
  public enum Kind {
    case warning
    case error
  }

  @Environment(\.theme) private var theme

  private let message: String
  private let kind: Kind
  /// Overrides the kind's default glyph. Notices that aren't about invalid
  /// configuration read better with their own icon — a stalled turn is a
  /// clock, not a warning triangle — while keeping one notice surface.
  private let systemImage: String?
  private let actionTitle: String?
  private let action: (() -> Void)?
  private let onDismiss: (() -> Void)?

  public init(
    _ message: String,
    kind: Kind,
    systemImage: String? = nil,
    actionTitle: String? = nil,
    action: (() -> Void)? = nil,
    onDismiss: (() -> Void)? = nil
  ) {
    self.message = message
    self.kind = kind
    self.systemImage = systemImage
    self.actionTitle = actionTitle
    self.action = action
    self.onDismiss = onDismiss
  }

  public var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: systemImage ?? defaultSystemImage)
        .font(.caption)
      Text(message)
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      if hasControls {
        // Expanded touch targets must not overlap. The visible
        // controls stay compact while their hit regions meet at the
        // midpoint of this platform-aware gap.
        HStack(spacing: max(8, Typography.minimumInteractiveTargetSize - 20)) {
          if let actionTitle, let action {
            Button(actionTitle, action: action)
              .buttonStyle(.plain)
              .font(.caption.weight(.semibold))
              .expandedHitTarget(
                base: 20,
                minimum: Typography.minimumInteractiveTargetSize
              )
          }
          if let onDismiss {
            Button(action: onDismiss) {
              #if os(iOS)
                Image(systemName: "xmark")
                  .font(.caption.weight(.semibold))
                  .scaledFrame(width: 20, height: 20, relativeTo: .caption)
              #else
                Image(systemName: "xmark")
                  .font(.caption.weight(.semibold))
              #endif
            }
            .buttonStyle(.plain)
            .expandedHitTarget(
              base: 20,
              minimum: Typography.minimumInteractiveTargetSize
            )
            .accessibilityLabel("Dismiss notice")
          }
        }
      }
    }
    .foregroundStyle(foregroundColor)
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      ZStack {
        // Notices float beyond the transcript mask, so their base must
        // be opaque or transcript text bleeds through the status tint.
        RoundedRectangle(cornerRadius: 8)
          .fill(theme.windowBackground)
        RoundedRectangle(cornerRadius: 8)
          .fill(foregroundColor.opacity(0.08))
      }
    }
    // Actionable notices expose their controls as separate VoiceOver
    // elements; passive notices read as one concise announcement.
    .accessibilityElement(children: hasControls ? .contain : .combine)
  }

  private var hasControls: Bool {
    action != nil || onDismiss != nil
  }

  private var defaultSystemImage: String {
    kind == .error ? "exclamationmark.triangle.fill" : "exclamationmark.triangle"
  }

  private var foregroundColor: Color {
    kind == .error ? theme.statusError : theme.statusWarn
  }
}
