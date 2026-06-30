import SwiftUI
import ACPKit

/// Displays the agent's execution plan as a checklist.
struct PlanView: View {
    let plan: Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Plan")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(plan.entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: symbol(for: entry.status))
                        .foregroundStyle(color(for: entry.status))
                        .font(.caption)
                    Text(entry.content)
                        .font(.callout)
                        .strikethrough(entry.status == .completed, color: .secondary)
                        .foregroundStyle(entry.status == .completed ? .secondary : .primary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
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
        case .pending: return .secondary
        case .inProgress: return .accentColor
        case .completed: return .green
        }
    }
}

#Preview {
    PlanView(plan: Plan(entries: [
        PlanEntry(content: "Read the existing code", priority: .high, status: .completed),
        PlanEntry(content: "Implement the change", priority: .medium, status: .inProgress),
        PlanEntry(content: "Add tests", priority: .low, status: .pending)
    ]))
    .padding()
    .frame(width: 460)
}
