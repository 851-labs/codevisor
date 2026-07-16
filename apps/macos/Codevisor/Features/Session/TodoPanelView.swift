import SwiftUI
import ACPKit

/// The session's todo checklist, pinned above the composer (codex-CLI style)
/// for every harness — codex `update_plan`, Claude TodoWrite, ACP plans.
/// Collapsible: the header always shows progress and the current step; the
/// body lists every step.
struct TodoPanelView: View {
    let plan: Plan
    @Binding var isExpanded: Bool
    var glassNamespace: Namespace.ID? = nil
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var completedCount: Int {
        plan.entries.count { $0.status == .completed }
    }

    private var currentStep: PlanEntry? {
        plan.entries.first { $0.status == .inProgress } ?? plan.entries.first { $0.status == .pending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                // The measured reveal below owns the animation transaction.
                // Toggling directly keeps sibling layout and the glass surface
                // from interpolating independently of the clipped content.
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Todos")
                        .font(.caption.weight(.semibold))
                    Text("\(completedCount)/\(plan.entries.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if !isExpanded, let current = currentStep {
                        Text(current.content)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .foregroundStyle(.tertiary)
                        .animation(Motion.indicator(reduceMotion: reduceMotion), value: isExpanded)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Todos, \(completedCount) of \(plan.entries.count) done")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(.isButton)

            TranscriptDisclosureContentReveal(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(plan.entries.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: symbol(for: entry.status))
                                .foregroundStyle(color(for: entry.status))
                                .font(.caption)
                            Text(entry.content)
                                .font(.callout.weight(entry.status == .inProgress ? .medium : .regular))
                                .strikethrough(entry.status == .completed, color: .secondary)
                                .foregroundStyle(textStyle(for: entry.status))
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .composerGlassSurface(
            cornerRadius: ComposerGlassStyle.accessoryCornerRadius,
            id: .todos,
            in: glassNamespace
        )
    }

    private func symbol(for status: PlanEntryStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private func color(for status: PlanEntryStatus) -> Color {
        switch status {
        case .pending: return Color.secondary.opacity(0.6)
        case .inProgress: return Color.primary
        case .completed: return theme.statusOK
        }
    }

    private func textStyle(for status: PlanEntryStatus) -> AnyShapeStyle {
        switch status {
        case .pending: return AnyShapeStyle(.secondary)
        case .inProgress: return AnyShapeStyle(Color.primary)
        case .completed: return AnyShapeStyle(.secondary)
        }
    }
}

#Preview {
    @Previewable @State var isExpanded = true
    return TodoPanelView(
        plan: Plan(entries: [
            PlanEntry(content: "Read the existing code", priority: .high, status: .completed),
            PlanEntry(content: "Implement the change", priority: .medium, status: .inProgress),
            PlanEntry(content: "Add tests", priority: .low, status: .pending)
        ]),
        isExpanded: $isExpanded
    )
    .padding()
    .frame(width: 520)
}
