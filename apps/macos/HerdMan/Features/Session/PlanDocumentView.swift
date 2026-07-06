import SwiftUI
import StreamMarkdown

/// The "Proposed Plan" card: a free-form markdown plan the agent produced in
/// plan mode (Claude ExitPlanMode, codex plan items), rendered with the same
/// markdown pipeline as the final answer — the codex CLI's "Proposed Plan"
/// cell equivalent.
struct PlanDocumentView: View {
    let markdown: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.caption2)
                Text("Proposed Plan")
                    .font(.callout.weight(.semibold))
            }
            .foregroundStyle(theme.accent)
            StreamingMarkdownView(markdown)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.accent.opacity(0.2), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposed plan")
    }
}

#Preview {
    PlanDocumentView(markdown: """
    # Add goal banner

    1. Extend the wire schema with `SessionGoal`
    2. Map codex `thread/goal/*` in the provider
    3. Render the banner above the composer

    **Verification**: run the dev app and set a goal.
    """)
    .padding()
    .frame(width: 560)
}
