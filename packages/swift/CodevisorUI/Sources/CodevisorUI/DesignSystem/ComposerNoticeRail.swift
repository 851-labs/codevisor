import SwiftUI

public struct ComposerNoticeRail: View {
  private var cardStyle = ComposerCardStyle()
  public enum Kind {
    case warning
    case error
  }

  private let message: String
  private let details: String?
  private let kind: Kind
  private let systemImage: String?
  private let actionTitle: String?
  private let action: (() -> Void)?
  private let onDismiss: (() -> Void)?
  @State private var isShowingDetails = false

  public init(
    _ message: String,
    details: String? = nil,
    kind: Kind,
    systemImage: String? = nil,
    actionTitle: String? = nil,
    action: (() -> Void)? = nil,
    onDismiss: (() -> Void)? = nil
  ) {
    self.message = message
    self.details = details
    self.kind = kind
    self.systemImage = systemImage
    self.actionTitle = actionTitle
    self.action = action
    self.onDismiss = onDismiss
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      headline
      if isShowingDetails, let details {
        ScrollView {
          Text(details)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 240)
      }
    }
    .foregroundStyle(foregroundColor)
    .padding(ComposerCardStyle.contentPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      ZStack {
        cardStyle.shape
          .fill(Color.windowBackgroundColor)
        cardStyle.shape
          .fill(foregroundColor.opacity(0.08))
      }
    }
    .accessibilityElement(children: hasControls ? .contain : .combine)
  }

  private var headline: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: systemImage ?? defaultSystemImage)
        .font(.caption)
      Text(message)
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      if hasControls {
        HStack(spacing: max(8, Typography.minimumInteractiveTargetSize - 20)) {
          if details != nil {
            Button(isShowingDetails ? "Hide Details" : "Show Details") { isShowingDetails.toggle() }
              .buttonStyle(.plain)
              .font(.caption.weight(.semibold))
              .expandedHitTarget(
                base: 20,
                minimum: Typography.minimumInteractiveTargetSize
              )
          }
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
  }

  private var hasControls: Bool {
    details != nil || action != nil || onDismiss != nil
  }

  private var defaultSystemImage: String {
    kind == .error ? "exclamationmark.triangle.fill" : "exclamationmark.triangle"
  }

  private var foregroundColor: Color {
    kind == .error ? .red : .orange
  }
}
