import SwiftUI
import ACPKit
import StreamMarkdown

/// A single tool call as a one-line title that expands to a content card
/// (terminal output, diff, or text) with a status badge.
struct ToolCallRow: View {
    let call: ToolCall
    @State private var isExpanded = false

    private var hasContent: Bool { !(call.content?.isEmpty ?? true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(call.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
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
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .clipped()
    }
}

/// The expanded content of a tool call: a labeled card with the output and a
/// success/failure badge.
struct ToolCallContentCard: View {
    let call: ToolCall

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

            if call.status == .completed || call.status == .failed {
                HStack { Spacer(); statusBadge }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
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
                .foregroundStyle(.green)
        case .failed:
            Label("Failed", systemImage: "xmark")
                .font(.caption2)
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 10) {
        ToolCallRow(call: ToolCall(toolCallId: "1", title: "Ran rg -n \"barnsong|village|farm|MCP\"", kind: .execute, status: .completed,
                                   content: [.content(.text("$ rg -n \"barnsong\"\nzsh:1: no matches found: wrangler*"))]))
        ToolCallRow(call: ToolCall(toolCallId: "2", title: "Searched for files", kind: .search, status: .completed))
        ToolCallRow(call: ToolCall(toolCallId: "3", title: "Read README.md", kind: .read, status: .completed,
                                   content: [.content(.text("# Barnsong"))]))
    }
    .padding()
    .frame(width: 520)
}
