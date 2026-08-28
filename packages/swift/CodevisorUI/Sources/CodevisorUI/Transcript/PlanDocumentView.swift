import SwiftUI
import StreamMarkdown

/// The "Proposed Plan" card: a free-form markdown plan the agent produced in
/// plan mode (Claude ExitPlanMode, codex plan items), rendered with the same
/// markdown pipeline as the final answer — the codex CLI's "Proposed Plan"
/// cell equivalent.
public struct PlanDocumentView: View {
    let markdown: String

    public init(markdown: String) {
        self.markdown = markdown
    }
    @Environment(\.theme) private var theme

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.caption2)
                Text("Proposed Plan")
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            StreamingMarkdownView(markdown)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardBackground))
        .themedCardShadow(theme)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposed plan")
    }
}

/// The independently virtualized top of a proposed-plan card.
public struct PlanDocumentHeaderView: View {
    @Environment(\.theme) private var theme

    public init() {}

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "list.bullet.clipboard")
                .font(.caption2)
            Text("Proposed Plan")
                .font(.callout.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            PlanDocumentFragmentBackground(
                color: theme.cardBackground,
                includesTop: true,
                includesBottom: false
            )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposed plan")
    }
}

/// One Markdown block inside the independently virtualized proposed-plan card.
public struct PlanDocumentBlockView: View {
    private let block: MarkdownBlock
    private let documentSource: String
    private let streamID: String
    private let isStreaming: Bool
    private let isFirst: Bool
    private let isLast: Bool
    @Environment(\.theme) private var theme
    @Environment(\.markdownTheme) private var markdownTheme

    public init(
        block: MarkdownBlock,
        documentSource: String,
        streamID: String,
        isStreaming: Bool,
        isFirst: Bool,
        isLast: Bool
    ) {
        self.block = block
        self.documentSource = documentSource
        self.streamID = streamID
        self.isStreaming = isStreaming
        self.isFirst = isFirst
        self.isLast = isLast
    }

    public var body: some View {
        MarkdownBlockRenderView(
            block: block,
            documentSource: documentSource,
            streamID: streamID,
            isStreaming: isStreaming
        )
        .padding(.horizontal, 12)
        .padding(.top, isFirst ? 0 : markdownTheme.blockSpacing)
        .padding(.bottom, isLast ? 12 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            PlanDocumentFragmentBackground(
                color: theme.cardBackground,
                includesTop: false,
                includesBottom: isLast
            )
        )
    }
}

private struct PlanDocumentFragmentBackground: View {
    let color: AnyShapeStyle
    let includesTop: Bool
    let includesBottom: Bool

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: includesTop ? 8 : 0,
            bottomLeadingRadius: includesBottom ? 8 : 0,
            bottomTrailingRadius: includesBottom ? 8 : 0,
            topTrailingRadius: includesTop ? 8 : 0
        )
        .fill(color)
        .overlay {
            PlanDocumentFragmentBorder(
                includesTop: includesTop,
                includesBottom: includesBottom
            )
            .stroke(.separator, lineWidth: 1)
        }
    }
}

private struct PlanDocumentFragmentBorder: Shape {
    let includesTop: Bool
    let includesBottom: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 8
        var path = Path()
        if includesTop {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + radius, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else if includesBottom {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + radius, y: rect.maxY),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        return path
    }
}

#Preview {
    PlanDocumentView(
        markdown: """
            # Add goal banner

            1. Extend the wire schema with `SessionGoal`
            2. Map codex `thread/goal/*` in the provider
            3. Render the banner above the composer

            **Verification**: run the dev app and set a goal.
            """
    )
    .padding()
    .frame(width: 560)
}
