import ACPKit
#if canImport(AppKit)
  import AppKit
#endif
import CodevisorCore
import StreamMarkdown
import SwiftUI

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
  @State private var totalsCache = DiffTotalsCache()
  @State private var isHovering = false
  @Environment(\.toolRowsHighlightOnHover) private var highlightsOnHover

  private var hasDetails: Bool { call.hasPresentableDetails }

  private var counterTotals: LineDiff.Totals? {
    totalsCache.totals(for: call)
  }

  private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }
  private var disclosureKey: TranscriptDisclosureStore.Key { .toolCall(call.toolCallId) }
  private var isExpanded: Bool { store.isExpanded(disclosureKey, default: false) }

  public var body: some View {
    let totals = counterTotals
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: ToolIconMetrics.spacing) {
        ToolCallIconView(icon: call.icon)
        rowLabel(totals: totals)
      }
      .contentShape(Rectangle())
      .onHover { isHovering = $0 }
      .onTapGesture(perform: toggleDetails)
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(hasDetails ? .isButton : [])
      .accessibilityAction { toggleDetails() }

      TranscriptDisclosureContentReveal(isExpanded: isExpanded && hasDetails) {
        ToolCallDetails(call: call)
          .padding(.top, 6)
          .padding(.leading, ToolIconMetrics.labelInset)
      }
    }
    .task(id: diffPreparationRevision) {
      await prepareSettledDiffs()
    }
  }

  private func toggleDetails() {
    guard hasDetails else { return }
    let change = { store.toggle(disclosureKey, default: false) }
    performAnchoredDisclosureChange?(change) ?? change()
  }

  private func rowLabel(totals: LineDiff.Totals?) -> some View {
    HStack(spacing: 6) {
      Text(call.displayTitle(diffTotals: totals))
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
        .truncationMode(.tail)
        .foregroundStyle(highlightsOnHover && hasDetails && isHovering ? .primary : .secondary)
        .shimmering(isTurnActive && !call.isSettled)
      if let totals {
        DiffCounter(totals: totals)
      }
      if hasDetails {
        TranscriptDisclosureChevron(expanded: isExpanded)
      }
      Spacer(minLength: 0)
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

struct ToolCallDetails: View {
  let call: ToolCall

  var body: some View {
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
    } else if let read = call.readFileOutput {
      ReadFileBodyView(read: read)
    } else {
      ToolCallContentCard(call: call)
    }
  }

  private var hasOnlyDiffContent: Bool {
    guard let content = call.content, !content.isEmpty else { return false }
    return content.allSatisfy { block in
      if case .diff = block { return true }
      return false
    }
  }

}

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

  private static func droppingTrailingNewlines(_ text: String) -> String {
    var end = text.endIndex
    while end > text.startIndex, text[text.index(before: end)].isNewline {
      end = text.index(before: end)
    }
    return String(text[..<end])
  }

  var body: some View {
    let command = call.shellCommand
    let output = outputText ?? ""
    VStack(alignment: .leading, spacing: 8) {
      if command != nil || !output.isEmpty || call.isSettled {
        PlainCodeBodyView(
          command: command,
          output: Self.droppingTrailingNewlines(output),
          followsTail: !call.isSettled
        )
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

public struct ToolCallContentCard: View {
  let call: ToolCall

  public var body: some View {
    if let workflow = call.codevisorWorkflowDetails {
      CodevisorWorkflowDetailView(details: workflow)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else if let skill = call.skillText {
      PlainCodeBodyView(output: skill)
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

      if call.isSettled, call.kind == .execute || call.status == .failed || call.status == .cancelled {
        HStack {
          Spacer(); ToolCallStatusBadge(call: call)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

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

struct ToolCallMonospacedText: View {
  let title: String
  let text: String
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
