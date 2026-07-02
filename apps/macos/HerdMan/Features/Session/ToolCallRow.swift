import SwiftUI
import ACPKit
import HerdManCore
import StreamMarkdown

/// A single tool call as a one-line title that expands to a content card
/// (terminal output, diff, or text) with a status badge. The title shimmers
/// while the call is running, and edit calls carry an animated +N/−N counter
/// that rolls as streamed diff stats arrive.
struct ToolCallRow: View {
    let call: ToolCall
    var isTurnActive: Bool = false
    @Environment(\.theme) private var theme
    @State private var isExpanded = false

    private var hasContent: Bool { !(call.content?.isEmpty ?? true) }

    /// Counters render for any edit call from the moment it starts (`+0 −0`)
    /// so the roll-up is visible, and for any call reporting diff stats.
    private var counterTotals: LineDiff.Totals? {
        call.diffTotals ?? (call.kind == .edit ? LineDiff.Totals(added: 0, removed: 0) : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(call.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                    .shimmering(isTurnActive && !call.isSettled)
                if let totals = counterTotals {
                    DiffCounter(totals: totals)
                }
                if hasContent {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if hasContent { withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() } }
            }

            if isExpanded, hasContent {
                ToolCallContentCard(call: call)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .clipped()
    }
}

/// The +N/−N added/removed-lines counter. Digits roll up and down via
/// `numericText` as streamed diff stats update the totals.
struct DiffCounter: View {
    let totals: LineDiff.Totals
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(totals.added)")
                .foregroundStyle(theme.diffAddedFg)
                .contentTransition(.numericText(value: Double(totals.added)))
            Text("−\(totals.removed)")
                .foregroundStyle(theme.diffRemovedFg)
                .contentTransition(.numericText(value: Double(totals.removed)))
        }
        .font(.caption.monospacedDigit())
        .animation(.snappy(duration: 0.3), value: totals)
    }
}

/// The expanded content of a tool call: a labeled card with the output and a
/// success/failure badge.
struct ToolCallContentCard: View {
    let call: ToolCall
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ForEach(Array((call.content ?? []).enumerated()), id: \.offset) { _, content in
                contentView(content)
            }

            if call.isSettled {
                HStack { Spacer(); statusBadge }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardBackground))
    }

    @ViewBuilder
    private func contentView(_ content: ToolCallContent) -> some View {
        switch content {
        case let .content(block):
            if let text = block.textValue {
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .diff(path, oldText, newText):
            DiffView(path: path, oldText: oldText, newText: newText)
        case let .terminal(terminalId):
            Text("Terminal \(terminalId)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var label: String {
        switch call.kind {
        case .execute: return "Shell"
        case .read: return "File"
        case .edit: return "Diff"
        case .search: return "Search"
        case .fetch: return "Fetch"
        default: return "Output"
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch call.status {
        case .completed:
            Label("Success", systemImage: "checkmark")
                .font(.caption2)
                .foregroundStyle(theme.statusOK)
        case .failed:
            Label("Failed", systemImage: "xmark")
                .font(.caption2)
                .foregroundStyle(theme.statusError)
        case .cancelled:
            Label("Cancelled", systemImage: "slash.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 10) {
        ToolCallRow(call: ToolCall(toolCallId: "1", title: "Ran rg -n \"barnsong|village|farm|MCP\"", kind: .execute, status: .completed,
                                   content: [.content(.text("$ rg -n \"barnsong\"\nzsh:1: no matches found: wrangler*"))]))
        ToolCallRow(
            call: ToolCall(toolCallId: "2", title: "Edited release.yml", kind: .edit, status: .inProgress,
                           diffStats: [ToolCallDiffStat(path: "release.yml", added: 13, removed: 7)]),
            isTurnActive: true
        )
        ToolCallRow(call: ToolCall(toolCallId: "3", title: "Read README.md", kind: .read, status: .completed,
                                   content: [.content(.text("# Barnsong"))]))
        ToolCallRow(call: ToolCall(toolCallId: "4", title: "Edited main.swift", kind: .edit, status: .cancelled,
                                   content: [.diff(path: "main.swift", oldText: "let a = 1\n", newText: "let a = 2\n")]))
    }
    .padding()
    .frame(width: 520)
}
