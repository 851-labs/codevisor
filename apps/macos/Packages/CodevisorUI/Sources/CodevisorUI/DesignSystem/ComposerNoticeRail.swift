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
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notice")
            }
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(foregroundColor.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
    }

    private var defaultSystemImage: String {
        kind == .error ? "exclamationmark.triangle.fill" : "exclamationmark.triangle"
    }

    private var foregroundColor: Color {
        kind == .error ? theme.statusError : theme.statusWarn
    }
}
