import SwiftUI
import ACPKit
import HerdManCore

/// A collapsed group of consecutive tool calls, summarized as one row
/// (e.g. "Searched code, ran 2 commands") that expands to the individual calls.
struct ToolGroupView: View {
    let calls: [ToolCall]
    var isTurnActive: Bool = false
    /// Kept open while the model is still working through this group (no text
    /// has followed it yet); collapses when the model moves on to prose.
    var autoExpanded: Bool = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Pinned to the first call's icon — a group's icon flipping
                // as more calls stream in reads as UI churn.
                Image(systemName: ToolCallSummary.symbol(calls.first.map { [$0] } ?? []))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(ToolCallSummary.describe(calls))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() } }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(calls) { call in
                        ToolCallRow(call: call, isTurnActive: isTurnActive)
                    }
                }
                .padding(.leading, 24)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .clipped()
        // The group follows the work: open while the model is working through
        // it so the live rows (shimmer, counters) are visible, closed once
        // the next text part arrives. Manual toggles still work in between.
        .onAppear {
            if autoExpanded { isExpanded = true }
        }
        .onChange(of: autoExpanded) { _, expanded in
            withAnimation(.snappy(duration: 0.25)) { isExpanded = expanded }
        }
    }
}

#Preview {
    ToolGroupView(calls: [
        ToolCall(toolCallId: "1", title: "Ran rg -n \"barnsong|village|farm\"", kind: .execute, status: .completed,
                 content: [.content(.text("no matches found"))]),
        ToolCall(toolCallId: "2", title: "Searched for files", kind: .search, status: .completed),
        ToolCall(toolCallId: "3", title: "Ran pwd && rg --files", kind: .execute, status: .completed)
    ])
    .padding()
    .frame(width: 520)
}
