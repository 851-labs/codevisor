import SwiftUI
import ACPKit
import CodevisorCore

/// A collapsed group of consecutive tool calls, summarized as one row
/// (e.g. "Searched code, ran 2 commands") that expands to the individual calls.
enum ToolGroupDisclosurePolicy {
    static func hasUnsettledCall(_ calls: [ToolCall]) -> Bool {
        calls.contains { !$0.isSettled }
    }

    static func shouldAutoExpand(_ calls: [ToolCall], followsLatestWork: Bool) -> Bool {
        followsLatestWork || hasUnsettledCall(calls)
    }

    static func isExpanded(_ calls: [ToolCall], disclosureExpansion: Bool) -> Bool {
        hasUnsettledCall(calls) || disclosureExpansion
    }
}

public struct ToolGroupView: View {
    let calls: [ToolCall]
    var isTurnActive: Bool = false
    /// Kept open while the model is still working through this group (no text
    /// has followed it yet). An unfinished call keeps the group open even when
    /// the model moves on to prose.
    var autoExpanded: Bool = false

    public init(calls: [ToolCall], isTurnActive: Bool = false, autoExpanded: Bool = false) {
        self.calls = calls
        self.isTurnActive = isTurnActive
        self.autoExpanded = autoExpanded
    }
    @Environment(\.transcriptDisclosure) private var disclosureStore
    @Environment(\.transcriptPerformAnchoredDisclosureChange) private var performAnchoredDisclosureChange

    // Disclosure hoisted to the session store (survives lazy remounts),
    // keyed by the group's first call id (groups only append, so it's stable).
    // The seed default follows the latest work and any unfinished calls; the
    // auto transition below writes through, and settled groups thereafter
    // change only by user tap.
    private static var iconFont: Font {
        #if os(iOS)
        .subheadline
        #else
        .callout
        #endif
    }

    private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }
    private var disclosureKey: TranscriptDisclosureStore.Key { .toolGroup(calls.first?.toolCallId ?? "") }
    private var hasUnsettledCall: Bool {
        ToolGroupDisclosurePolicy.hasUnsettledCall(calls)
    }
    private var shouldAutoExpand: Bool {
        ToolGroupDisclosurePolicy.shouldAutoExpand(calls, followsLatestWork: autoExpanded)
    }
    private var isExpanded: Bool {
        // Running output must stay visible even if an earlier stored toggle
        // says otherwise. Once every call settles, ordinary disclosure state
        // takes over again.
        ToolGroupDisclosurePolicy.isExpanded(
            calls,
            disclosureExpansion: store.isExpanded(disclosureKey, default: shouldAutoExpand)
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // Pinned to the first call's icon — a group's icon flipping
                // as more calls stream in reads as UI churn.
                Image(systemName: ToolCallSummary.symbol(calls.first.map { [$0] } ?? []))
                    // One notch under the row label on both platforms: macOS
                    // pairs a 12pt callout icon with 13pt body text; iOS rows
                    // label at callout 16, so the icon sits at subheadline 15.
                    .font(Self.iconFont)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(ToolCallSummary.describe(calls))
                    .foregroundStyle(.secondary)
                TranscriptDisclosureChevron(expanded: isExpanded)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // A live call owns the disclosure until it reaches a terminal
                // state; otherwise a tap could hide the progress it is meant
                // to keep visible.
                guard !hasUnsettledCall else { return }
                let change = { store.toggle(disclosureKey, default: shouldAutoExpand) }
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
        // The group follows the work and remains open while any call is
        // unfinished, so prose emitted while a yielded command is still
        // running cannot collapse its live row. It closes only after the group
        // has both stopped trailing and fully settled. Manual toggles work
        // once no call is live.
        //
        // No onAppear seed: the store default is `shouldAutoExpand`, so a
        // remount renders correctly without re-running a side effect.
        .onChange(of: shouldAutoExpand) { _, expanded in
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
