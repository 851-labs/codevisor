import Foundation
import ACPKit

/// A presentation item within the "Worked for…" section: a block of reasoning
/// text, or a group of consecutive tool calls summarized as one row.
public enum WorkedItem: Identifiable, Sendable, Equatable {
    case text(id: String, markdown: String)
    case toolGroup(id: String, calls: [ToolCall])

    public var id: String {
        switch self {
        case let .text(id, _): return "wtext:\(id)"
        case let .toolGroup(id, _): return "wgroup:\(id)"
        }
    }
}

public extension AssistantTurn {
    /// The worked-for entries grouped for display: consecutive tool calls are
    /// collapsed into a single `toolGroup`, with reasoning text in between.
    var workedItems: [WorkedItem] {
        var items: [WorkedItem] = []
        var group: [ToolCall] = []

        func flush() {
            guard let first = group.first else { return }
            items.append(.toolGroup(id: first.toolCallId, calls: group))
            group = []
        }

        for entry in workedEntries {
            switch entry {
            case let .text(id, markdown):
                flush()
                items.append(.text(id: id, markdown: markdown))
            case let .tool(call):
                group.append(call)
            }
        }
        flush()
        return items
    }
}

/// Summarizes a group of tool calls into a one-line description and an icon,
/// e.g. "Read 6 files" or "Searched code, ran 2 commands".
public enum ToolCallSummary {
    enum Category: Equatable {
        case edit, read, search, execute, fetch, delete, move, other
    }

    static func category(_ kind: ToolKind?) -> Category {
        switch kind {
        case .edit: return .edit
        case .read: return .read
        case .search: return .search
        case .execute: return .execute
        case .fetch: return .fetch
        case .delete: return .delete
        case .move: return .move
        default: return .other
        }
    }

    public static func describe(_ calls: [ToolCall]) -> String {
        guard !calls.isEmpty else { return "" }
        var order: [Category] = []
        var counts: [Category: Int] = [:]
        for call in calls {
            let category = category(call.kind)
            if counts[category] == nil { order.append(category) }
            counts[category, default: 0] += 1
        }
        let phrases = order.map { phrase($0, counts[$0] ?? 0) }
        return capitalizingFirst(join(phrases))
    }

    public static func symbol(_ calls: [ToolCall]) -> String {
        var counts: [Category: Int] = [:]
        for call in calls { counts[category(call.kind), default: 0] += 1 }
        let dominant = counts.max { lhs, rhs in lhs.value < rhs.value }?.key ?? .other
        switch dominant {
        case .search: return "magnifyingglass"
        case .execute: return "terminal"
        case .edit: return "pencil"
        case .read: return "doc.text"
        case .fetch: return "arrow.down.circle"
        case .delete: return "trash"
        case .move: return "arrow.right.doc.on.clipboard"
        case .other: return "wrench.and.screwdriver"
        }
    }

    // MARK: - Phrasing

    static func phrase(_ category: Category, _ count: Int) -> String {
        let single = count == 1
        switch category {
        case .read: return single ? "read a file" : "read \(count) files"
        case .search: return "searched code"
        case .execute: return single ? "ran a command" : "ran \(count) commands"
        case .edit: return single ? "edited a file" : "edited \(count) files"
        case .fetch: return single ? "fetched a resource" : "fetched \(count) resources"
        case .delete: return single ? "deleted a file" : "deleted \(count) files"
        case .move: return single ? "moved a file" : "moved \(count) files"
        case .other: return single ? "ran a tool" : "ran \(count) tools"
        }
    }

    static func join(_ phrases: [String]) -> String {
        switch phrases.count {
        case 0: return "ran tools"
        case 1: return phrases[0]
        case 2: return "\(phrases[0]) and \(phrases[1])"
        default: return phrases.dropLast().joined(separator: ", ") + ", and " + (phrases.last ?? "")
        }
    }

    static func capitalizingFirst(_ string: String) -> String {
        guard let first = string.first else { return string }
        return first.uppercased() + string.dropFirst()
    }
}
