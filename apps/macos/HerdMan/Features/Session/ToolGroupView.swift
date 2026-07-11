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
    @Environment(\.transcriptDisclosure) private var disclosureStore
    @Environment(\.transcriptPerformAnchoredDisclosureChange) private var performAnchoredDisclosureChange

    // Disclosure hoisted to the session store (survives lazy remounts),
    // keyed by the group's first call id (groups only append, so it's stable).
    // The seed default IS `autoExpanded`, so before any user tap the group
    // follows the work; the auto transition below writes through, and settled
    // groups thereafter change only by user tap.
    private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }
    private var disclosureKey: TranscriptDisclosureStore.Key { .toolGroup(calls.first?.toolCallId ?? "") }
    private var isExpanded: Bool { store.isExpanded(disclosureKey, default: autoExpanded) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // Pinned to the first call's icon — a group's icon flipping
                // as more calls stream in reads as UI churn.
                Image(systemName: ToolCallSummary.symbol(calls.first.map { [$0] } ?? []))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(ToolCallSummary.describe(calls))
                    .foregroundStyle(.secondary)
                TranscriptDisclosureChevron(expanded: isExpanded)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                let change = { store.toggle(disclosureKey, default: autoExpanded) }
                performAnchoredDisclosureChange?(change) ?? change()
            }

            TranscriptDisclosureContentReveal(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(calls) { call in
                        ToolCallRow(call: call, isTurnActive: isTurnActive)
                    }
                }
                .padding(.leading, 24)
                .padding(.top, 8)
            }
        }
        // The group follows the work: open while the model is working through
        // it so the live rows (shimmer, counters) are visible, closed once
        // the next text part arrives. Manual toggles still work in between.
        // (No onAppear seed — the store default IS autoExpanded, so a remount
        // renders correctly without re-running a side effect.)
        .onChange(of: autoExpanded) { _, expanded in
            store.setExpanded(disclosureKey, expanded)
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
