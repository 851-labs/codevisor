import SwiftUI
import ACPKit
import CodevisorCore

public struct ToolGroupView: View {
    let group: ToolCallGroup
    var isTurnActive: Bool = false
    var followsLatestWork: Bool = false
    var automaticDisclosurePolicy: ToolGroupAutomaticDisclosurePolicy = .followLatestWork

    public init(
        group: ToolCallGroup,
        isTurnActive: Bool = false,
        followsLatestWork: Bool = false,
        automaticDisclosurePolicy: ToolGroupAutomaticDisclosurePolicy = .followLatestWork
    ) {
        self.group = group
        self.isTurnActive = isTurnActive
        self.followsLatestWork = followsLatestWork
        self.automaticDisclosurePolicy = automaticDisclosurePolicy
    }
    @Environment(\.transcriptDisclosure) private var disclosureStore
    @Environment(\.transcriptPerformAnchoredDisclosureChange) private var performAnchoredDisclosureChange

    private static var iconFont: Font {
        #if os(iOS)
            .subheadline
        #else
            .callout
        #endif
    }

    private static var iconColumnWidth: CGFloat {
        #if os(iOS)
            // The terminal symbol is slightly wider than the old 16pt column.
            // Keep its ink inside the clipped transcript-row host.
            18
        #else
            16
        #endif
    }

    private static var headerSpacing: CGFloat {
        #if os(iOS)
            // Preserve the existing 24pt icon-column-plus-gap label inset.
            6
        #else
            8
        #endif
    }

    private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }
    private var disclosureContext: ToolGroupDisclosureContext {
        ToolGroupDisclosureContext(
            hasUnsettledCall: group.hasUnsettledCall,
            followsLatestWork: followsLatestWork
        )
    }

    public var body: some View {
        let context = disclosureContext
        let disclosure = store.toolGroupDisclosure(
            id: group.id,
            policy: automaticDisclosurePolicy,
            initialContext: context
        )
        let isExpanded = disclosure.isExpanded

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Self.headerSpacing) {
                // Pinned to the first call's icon — a group's icon flipping
                // as more calls stream in reads as UI churn.
                Image(systemName: ToolCallSummary.symbol(group.calls.first.map { [$0] } ?? []))
                    // One notch under the row label on both platforms: macOS
                    // pairs a 12pt callout icon with 13pt body text; iOS rows
                    // label at callout 16, so the icon sits at subheadline 15.
                    .font(Self.iconFont)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.iconColumnWidth)
                Text(ToolCallSummary.describe(group.calls))
                    .foregroundStyle(.secondary)
                TranscriptDisclosureChevron(expanded: isExpanded)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard disclosure.isUserToggleEnabled else { return }
                let change = { disclosure.userToggled() }
                performAnchoredDisclosureChange?(change) ?? change()
            }

            TranscriptDisclosureContentReveal(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.calls) { call in
                        ToolCallRow(call: call, isTurnActive: isTurnActive)
                    }
                }
                .padding(.leading, 24)
                .padding(.top, 8)
            }
        }
        // The session-owned state machine is the only authority for expansion.
        // Reconciliation is idempotent and O(1); group activity was accumulated
        // while the transcript was already being grouped.
        .onChange(of: context, initial: true) { _, current in
            disclosure.reconcile(current)
        }
    }
}

#Preview {
    ToolGroupView(
        group: ToolCallGroup(calls: [
            ToolCall(
                toolCallId: "1", title: "Ran rg -n \"barnsong|village|farm\"", kind: .execute, status: .completed,
                content: [.content(.text("no matches found"))]),
            ToolCall(toolCallId: "2", title: "Searched for files", kind: .search, status: .completed),
            ToolCall(toolCallId: "3", title: "Ran pwd && rg --files", kind: .execute, status: .completed),
        ])
    )
    .padding()
    .frame(width: 520)
}
