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
  /// The content-diff fallback of `diffTotals` (a full Myers diff of the
  /// edited file), computed off the main thread: rows re-render on every
  /// stream flush while their turn is active, and diffing entire file
  /// contents in `body` was a per-render main-thread cost.
  @State private var totalsCache = DiffTotalsCache()

  private var hasDetails: Bool { call.hasPresentableDetails }

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
        if hasDetails {
          TranscriptDisclosureChevron(expanded: isExpanded)
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
      .onTapGesture {
        if hasDetails {
          let change = { store.toggle(disclosureKey, default: false) }
          performAnchoredDisclosureChange?(change) ?? change()
        }
      }

      TranscriptDisclosureContentReveal(isExpanded: isExpanded && hasDetails) {
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
          } else if call.kind == .execute {
            ShellToolCallDetails(call: call)
          } else {
            ToolCallContentCard(call: call)
          }
        }
        .padding(.top, 6)
      }
    }
    // Structural diffing is independent of syntax colors. Warm it once a
    // call settles, while the collapsed title is already mounted, so an
    // expansion can draw plain rows in its first frame.
    .task(id: diffPreparationRevision) {
      await prepareSettledDiffs()
    }
  }

  private var diffPreparationRevision: Int {
    var hasher = Hasher()
    hasher.combine(call.status)
    for block in call.content ?? [] {
      if case let .diff(path, oldText, newText) = block {
        hasher.combine(path)
        hasher.combine(oldText?.utf8.count ?? -1)
        hasher.combine(newText.utf8.count)
      }
    }
    return hasher.finalize()
  }

  private func prepareSettledDiffs() async {
    guard call.isSettled else { return }
    for block in call.content ?? [] {
      guard case let .diff(_, oldText, newText) = block else { continue }
      _ = await DiffStructureCache.shared.prepare(
        DiffStructureCache.Key(oldText: oldText, newText: newText)
      )
      guard !Task.isCancelled else { return }
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

/// Shell commands use the same editor-like card and single-document viewport
/// as file diffs, minus gutters, syntax colors, and changed-line fills.
private struct ShellToolCallDetails: View {
  let call: ToolCall

  private var outputText: String? {
    if let rawOutput = call.rawOutputDetailSection() {
      return rawOutput.text
    }

    let textBlocks = (call.content ?? []).compactMap { content -> String? in
      guard case let .content(block) = content,
        case let .text(text, _) = block
      else { return nil }
      return text
    }
    if !textBlocks.isEmpty {
      return textBlocks.joined(separator: "\n")
    }

    let terminals = (call.content ?? []).compactMap { content -> String? in
      guard case let .terminal(terminalId) = content else { return nil }
      return "Terminal \(terminalId)"
    }
    return terminals.isEmpty ? nil : terminals.joined(separator: "\n")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let outputText {
        PlainOutputView(
          title: "Shell",
          text: outputText,
          emptyMessage: "No output"
        )
      } else if call.isSettled {
        PlainOutputView(title: "Shell", text: "", emptyMessage: "No output")
      }

      ForEach(Array((call.content ?? []).enumerated()), id: \.offset) { _, content in
        supplementaryContent(content)
      }
    }
  }

  @ViewBuilder
  private func supplementaryContent(_ content: ToolCallContent) -> some View {
    switch content {
    case let .content(block):
      if case let .resourceLink(link) = block {
        ToolSourceLinkView(link: link)
      }
    case let .diff(path, oldText, newText):
      DiffView(path: path, oldText: oldText, newText: newText)
    case .terminal:
      EmptyView()
    }
  }
}

/// The expanded content of a tool call: its output directly under the row,
/// and a success/failure badge.
public struct ToolCallContentCard: View {
  let call: ToolCall

  public var body: some View {
    if let workflow = call.codevisorWorkflowDetails {
      // The highlighted code block brings its own frame.
      CodevisorWorkflowDetailView(details: workflow)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      genericCard
    }
  }

  private var genericCard: some View {
    let rawSections = call.rawDetailSections()
    let content = call.content ?? []
    return VStack(alignment: .leading, spacing: 8) {
      ForEach(rawSections) { section in
        ToolCallRawSectionView(section: section)
      }

      ForEach(Array(content.enumerated()), id: \.offset) { _, content in
        contentView(content)
      }

      // The status badge only earns its place on command output —
      // reads/edits/searches signal success by their content.
      if call.isSettled, call.kind == .execute || call.status == .failed || call.status == .cancelled {
        HStack {
          Spacer(); ToolCallStatusBadge(call: call)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// What the output is, named like a code block's language or a diff's
  /// file: the file a read returned, or the kind of output.
  private var label: String {
    if call.kind == .read, let path = call.locations?.first?.path {
      let name = (path as NSString).lastPathComponent
      return name.isEmpty ? path : name
    }
    switch call.kind {
    case .execute: return "Shell"
    case .search: return "Search"
    case .webSearch: return "Sources"
    case .fetch: return "Fetch"
    case .question: return "Answer"
    default: return "Output"
    }
  }

  @ViewBuilder
  private func contentView(_ content: ToolCallContent) -> some View {
    switch content {
    case let .content(block):
      switch block {
      case let .text(text, _):
        ToolCallMonospacedText(title: label, text: text)
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

}

private struct ToolCallStatusBadge: View {
  let call: ToolCall
  @Environment(\.theme) private var theme

  var body: some View {
    switch call.status {
    case .completed:
      Label(call.exitCode.map { "Exit \($0)" } ?? "Success", systemImage: "checkmark")
        .font(.caption2)
        .foregroundStyle(theme.statusOK)
    case .failed:
      Label(call.exitCode.map { "Exit \($0)" } ?? "Failed", systemImage: "xmark")
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

private struct ToolCallRawSectionView: View {
  let section: ToolCallRawSection
  @Environment(\.theme) private var theme
  @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement
  @State private var showsFullText = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if section.text.isEmpty {
        Text(section.kind == .output ? "No output" : "Empty")
          .font(.caption)
          .italic()
          .foregroundStyle(.secondary)
      } else {
        ToolCallMonospacedText(
          title: section.title,
          text: showsFullText ? section.text : section.preview,
          copyText: section.text
        )
      }
      if section.isTruncated {
        Button(showsFullText ? "Show less" : "Show full") {
          showsFullText.toggle()
          invalidateRowMeasurement?()
        }
        .buttonStyle(.plain)
        .font(.caption2.weight(.medium))
        .foregroundStyle(theme.accent)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Tool input and output text, shown like a code block: a header naming it
/// with a Copy button, then lines that keep their length and scroll sideways
/// when they overflow. Tall text scrolls within the same capped viewport as
/// shell output.
struct ToolCallMonospacedText: View {
  let title: String
  let text: String
  /// What Copy copies, when the text shown is a preview of it.
  var copyText: String?
  @Environment(\.theme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(title)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        CodeHeaderCopyButton(text: copyText ?? text)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)

      Divider()

      output
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(theme.codeBackground)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private var output: some View {
    #if canImport(AppKit)
      NativePlainOutputView(text: text, theme: theme, followsTail: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    #elseif canImport(UIKit)
      IOSNativePlainOutputView(text: text, theme: theme, followsTail: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    #else
      Text(text)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(theme.textPrimary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    #endif
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
