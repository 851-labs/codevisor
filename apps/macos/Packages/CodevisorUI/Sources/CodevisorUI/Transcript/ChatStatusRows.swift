import SwiftUI

public struct ChatActivityRow: View {
    private let message: String
    private let systemImage: String?
    private let shimmers: Bool

    public init(
        _ message: String,
        systemImage: String? = nil,
        shimmers: Bool = false
    ) {
        self.message = message
        self.systemImage = systemImage
        self.shimmers = shimmers
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.callout)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            if shimmers {
                ShimmeringText(text: message)
            } else {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

public struct ChatErrorRow: View {
    @Environment(\.theme) private var theme

    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        _ message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .foregroundStyle(theme.statusError)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.statusError.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
    }
}
