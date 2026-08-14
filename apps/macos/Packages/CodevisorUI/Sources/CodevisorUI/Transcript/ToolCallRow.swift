import ACPKit
#if canImport(AppKit)
    import AppKit
#endif
import CodevisorCore
import StreamMarkdown
import SwiftUI

/// A single tool call as a one-line title that expands to a content card
/// (terminal output, diff, or text) with a status badge. The title shimmers
/// while the call is running, and edit calls carry an animated +N/−N counter
/// that rolls as streamed diff stats arrive.
public struct ToolCallRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let call: ToolCall
    var isTurnActive: Bool = false

    public init(call: ToolCall, isTurnActive: Bool = false) {
        self.call = call
        self.isTurnActive = isTurnActive
    }
    @Environment(\.theme) private var theme
    @Environment(\.transcriptDisclosure) private var disclosureStore
    @Environment(\.transcriptPerformAnchoredDisclosureChange) private var performAnchoredDisclosureChange
    /// Memoizes the content-diff fallback of `diffTotals` (a full Myers diff
    /// of the edited file): rows re-render on every stream flush while their
    /// turn is active, and diffing entire file contents in `body` was a
    /// per-render main-thread cost.
    @State private var totalsCache = DiffTotalsCache()

    private var hasContent: Bool { !(call.content?.isEmpty ?? true) }

    private var hasOnlyDiffContent: Bool {
        guard let content = call.content, !content.isEmpty else { return false }
        return content.allSatisfy { block in
            if case .diff = block { return true }
            return false
        }
    }

    /// Counters render only once there is real diff data — a `+0 −0` badge on
    /// an adapter that never streams stats is noise.
    private var counterTotals: LineDiff.Totals? {
        totalsCache.totals(for: call)
    }

    // Disclosure state survives lazy row unmounts; tool cards seed collapsed.
    private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }
    private var disclosureKey: TranscriptDisclosureStore.Key { .toolCall(call.toolCallId) }
    private var isExpanded: Bool { store.isExpanded(disclosureKey, default: false) }

    public var body: some View {
        let totals = counterTotals
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(call.displayTitle(diffTotals: totals))
                    // The disclosure body shows output, never the full title,
                    // so at accessibility sizes reflow instead of truncating
                    // (HIG: minimize truncation as font size increases).
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                    .shimmering(isTurnActive && !call.isSettled)
                if let totals {
                    DiffCounter(totals: totals)
                }
                if hasContent {
                    TranscriptDisclosureChevron(expanded: isExpanded)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if hasContent {
                    let change = { store.toggle(disclosureKey, default: false) }
                    performAnchoredDisclosureChange?(change) ?? change()
                }
            }

            TranscriptDisclosureContentReveal(isExpanded: isExpanded && hasContent) {
                // Diffs carry their own card; wrapping them in the labeled
                // output card double-borders them for no benefit.
                Group {
                    if hasOnlyDiffContent {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array((call.content ?? []).enumerated()), id: \.offset) { _, content in
                                if case let .diff(path, oldText, newText) = content {
                                    DiffView(path: path, oldText: oldText, newText: newText)
                                }
                            }
                        }
                    } else {
                        ToolCallContentCard(call: call)
                    }
                }
                .padding(.top, 6)
            }
        }
    }
}

/// Process-level memo for the content-diff fallback of `diffTotals`, holding
/// SETTLED results only.
///
/// The per-row `DiffTotalsCache` below lives in `@State`, so it dies whenever
/// its row unmounts — a `LazyVStack` scroll past the viewport buffer, or a tab
/// switch, which rebuilds the whole chat screen. Revisiting an expanded edit
/// therefore re-ran a full Myers diff of the file's entire old and new text on
/// the main thread. Same rationale (and cap) as `DiffRenderCache`.
///
/// Keyed by full content, never by hash alone: a collision would render the
/// wrong +N/−N. In-progress calls are deliberately NOT stored — streaming
/// rewrites their text every flush, so admitting intermediates would evict the
/// settled entries that revisits actually re-encounter (the lesson already
/// recorded on `MarkdownSegmentCache` and `CodeHighlightResultCache`).
@MainActor
private final class SettledDiffTotalsCache {
    struct Block: Hashable {
        let oldText: String?
        let newText: String
    }

    struct Key: Hashable {
        let status: ToolCallStatus?
        let blocks: [Block]
    }

    static let shared = SettledDiffTotalsCache()

    private var entries: [Key: LineDiff.Totals] = [:]
    private var order: [Key] = []
    private let limit: Int

    /// Keys hold the full old/new texts, so the cap stays small.
    init(limit: Int = 24) {
        self.limit = max(1, limit)
    }

    func totals(for key: Key) -> LineDiff.Totals? {
        guard let value = entries[key] else { return nil }
        if order.last != key, let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
        return value
    }

    func store(_ value: LineDiff.Totals, for key: Key) {
        if entries[key] == nil {
            order.append(key)
            if order.count > limit {
                entries.removeValue(forKey: order.removeFirst())
            }
        }
        entries[key] = value
    }

    static func key(for call: ToolCall) -> Key {
        Key(
            status: call.status,
            blocks: (call.content ?? []).compactMap { block in
                if case let .diff(_, oldText, newText) = block {
                    // Strings are COW, so this retains rather than copies.
                    return Block(oldText: oldText, newText: newText)
                }
                return nil
            }
        )
    }
}

/// Memoizes `ToolCall.diffTotals` for the last-seen content. Streamed
/// `diffStats` are a cheap sum and pass straight through; the content-diff
/// fallback (a Myers diff over the whole file's old/new text) recomputes
/// only when the change key — status plus each diff block's text lengths —
/// moves, which tracks streamed edits (they grow the text) and settlement.
///
/// This cheap length-based key stays the first level: it costs no full-content
/// hashing, so a streaming row that re-renders every flush without changing
/// still short-circuits here. Only on a miss do we hash full content to consult
/// the process-level cache, which is what survives unmount/remount.
@MainActor
private final class DiffTotalsCache {
    private var key: Int?
    private var value: LineDiff.Totals?

    func totals(for call: ToolCall) -> LineDiff.Totals? {
        if let diffStats = call.diffStats, !diffStats.isEmpty {
            return call.diffTotals
        }
        var hasher = Hasher()
        hasher.combine(call.status)
        for block in call.content ?? [] {
            if case let .diff(_, oldText, newText) = block {
                hasher.combine(oldText?.utf8.count ?? -1)
                hasher.combine(newText.utf8.count)
            }
        }
        let newKey = hasher.finalize()
        if newKey == key { return value }

        // A first level miss is either a real content change (streaming) or a
        // freshly remounted row. Only the latter can hit the shared cache, and
        // it is the case that used to re-diff whole files.
        let sharedKey = SettledDiffTotalsCache.key(for: call)
        let computed: LineDiff.Totals?
        if let hit = SettledDiffTotalsCache.shared.totals(for: sharedKey) {
            computed = hit
        } else {
            computed = call.diffTotals
            if let computed, Self.isSettled(call.status) {
                SettledDiffTotalsCache.shared.store(computed, for: sharedKey)
            }
        }
        key = newKey
        value = computed
        return computed
    }

    private static func isSettled(_ status: ToolCallStatus?) -> Bool {
        switch status {
        case .completed, .failed, .cancelled: return true
        case .pending, .inProgress, nil: return false
        }
    }
}

/// The +N/−N added/removed-lines counter. Digits roll up and down via
/// `numericText` as streamed diff stats update the totals.
public struct DiffCounter: View {
    let totals: LineDiff.Totals

    public init(totals: LineDiff.Totals) {
        self.totals = totals
    }
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        HStack(spacing: 4) {
            Text("+\(totals.added)")
                .foregroundStyle(theme.diffAddedFg)
                .contentTransition(.numericText(value: Double(totals.added)))
            Text("−\(totals.removed)")
                .foregroundStyle(theme.diffRemovedFg)
                .contentTransition(.numericText(value: Double(totals.removed)))
        }
        .font(.caption.monospacedDigit())
        .animation(Motion.quick(reduceMotion: reduceMotion), value: totals)
    }
}

/// The expanded content of a tool call: a labeled card with the output and a
/// success/failure badge.
public struct ToolCallContentCard: View {
    let call: ToolCall
    @Environment(\.theme) private var theme

    public var body: some View {
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

            // The status badge only earns its place on command output —
            // reads/edits/searches signal success by their content.
            if call.isSettled, call.kind == .execute || call.status == .failed || call.status == .cancelled {
                HStack {
                    Spacer(); statusBadge
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardBackground))
        .themedCardShadow(theme)
    }

    @ViewBuilder
    private func contentView(_ content: ToolCallContent) -> some View {
        switch content {
        case let .content(block):
            switch block {
            case let .text(text, _):
                #if canImport(AppKit) || canImport(UIKit)
                    SelectableTextView(
                        attributedText: NSAttributedString(
                            string: text,
                            attributes: [
                                .font: OSFont.monospacedSystemFont(
                                    ofSize: OSFont.preferredFont(forTextStyle: .caption1).pointSize,
                                    weight: .regular
                                ),
                                .foregroundColor: OSColor(theme.textPrimary),
                            ]
                        ),
                        fillsWidth: true
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                #else
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                #endif
            // Web-search sources arrive as resource_link blocks; render each as
            // a tappable title over its host.
            case let .resourceLink(link):
                ToolSourceLinkView(link: link)
            default:
                EmptyView()
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
        case .webSearch: return "Sources"
        case .fetch: return "Fetch"
        case .question: return "Answer"
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

/// One web-search source: a tappable title over its host domain, opened in the
/// default browser. Falls back to the raw URI as the label when there's no
/// title and to plain text when the URI won't parse.
public struct ToolSourceLinkView: View {
    let link: ResourceLink
    @Environment(\.theme) private var theme

    private var label: String {
        let title = link.title ?? link.name
        return title.isEmpty ? link.uri : title
    }

    public var body: some View {
        if let url = URL(string: link.uri) {
            Link(destination: url) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "globe")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(theme.accent)
                            .lineLimit(1)
                        Text(url.host ?? link.uri)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(link.uri)
        } else {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 10) {
        ToolCallRow(
            call: ToolCall(
                toolCallId: "1", title: "Ran rg -n \"barnsong|village|farm|MCP\"", kind: .execute, status: .completed,
                content: [.content(.text("$ rg -n \"barnsong\"\nzsh:1: no matches found: wrangler*"))]))
        ToolCallRow(
            call: ToolCall(
                toolCallId: "2", title: "Edited release.yml", kind: .edit, status: .inProgress,
                diffStats: [ToolCallDiffStat(path: "release.yml", added: 13, removed: 7)]),
            isTurnActive: true
        )
        ToolCallRow(
            call: ToolCall(
                toolCallId: "3", title: "Read README.md", kind: .read, status: .completed,
                content: [.content(.text("# Barnsong"))]))
        ToolCallRow(
            call: ToolCall(
                toolCallId: "4", title: "Edited main.swift", kind: .edit, status: .cancelled,
                content: [.diff(path: "main.swift", oldText: "let a = 1\n", newText: "let a = 2\n")]))
        ToolCallRow(
            call: ToolCall(
                toolCallId: "5", title: "Searched for Swift 6.2 release date", kind: .webSearch, status: .completed,
                content: [
                    .content(
                        .resourceLink(
                            ResourceLink(
                                name: "Swift 6.2 Released | Swift.org",
                                uri: "https://www.swift.org/blog/swift-6.2-released/",
                                title: "Swift 6.2 Released | Swift.org"))),
                    .content(
                        .resourceLink(
                            ResourceLink(
                                name: "Releases · swiftlang/swift", uri: "https://github.com/swiftlang/swift/releases",
                                title: "Releases · swiftlang/swift"))),
                ]))
    }
    .padding()
    .frame(width: 520)
}
