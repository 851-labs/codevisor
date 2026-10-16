import Foundation
import ACPKit

public struct ToolCallGroup: Identifiable, Sendable, Equatable {
  public let id: String
  public let calls: [ToolCall]
  public let hasUnsettledCall: Bool

  public init(calls: [ToolCall]) {
    self.init(calls: calls, hasUnsettledCall: calls.contains { !$0.isSettled })
  }

  public init(calls: [ToolCall], hasUnsettledCall: Bool) {
    id = calls.first?.toolCallId ?? ""
    self.calls = calls
    self.hasUnsettledCall = hasUnsettledCall
  }
}

public enum WorkedItem: Identifiable, Sendable, Equatable {
  case text(id: String, markdown: String)
  case toolGroup(ToolCallGroup)
  case subagents(id: String, calls: [ToolCall])

  public static let thinkingLineID = "wthinking"
  public static let earlierHistoryLineID = "wearlier"
  public static let recentTextCount = 3

  public var id: String {
    switch self {
    case let .text(id, _): return "wtext:\(id)"
    case let .toolGroup(group): return "wgroup:\(group.id)"
    case let .subagents(id, _): return "wagent:\(id)"
    }
  }
}

extension Array where Element == WorkedItem {
  public var earlierHistoryCount: Int {
    var remaining = WorkedItem.recentTextCount
    for index in indices.reversed() {
      guard case .text = self[index] else { continue }
      remaining -= 1
      if remaining == 0 { return index }
    }
    return 0
  }
}

extension ToolCall {
  public var agentName: String {
    if let description = rawInput?["description"]?.stringValue,
      !description.trimmingCharacters(in: .whitespaces).isEmpty
    {
      return description
    }
    let title = displayTitle
    return title.hasPrefix("Agent: ") ? String(title.dropFirst("Agent: ".count)) : title
  }
}

extension AssistantTurn {
  public func isUnstartedSubagent(_ call: ToolCall) -> Bool {
    call.kind == .agent && call.rawInput == nil && subagents[call.toolCallId]?.entries.isEmpty != false
  }

  public var isStartingSubagent: Bool {
    isGenerating && toolCalls.contains { !$0.isSettled && isUnstartedSubagent($0) }
  }

  public var awaitedAgentCalls: [ToolCall] {
    guard isGenerating else { return [] }
    var awaited: [ToolCall] = []
    for entry in entries.reversed() {
      if case .contextCompaction = entry { continue }
      if entry.isBlankText { continue }
      guard case let .tool(call) = entry, call.kind == .agent else { break }
      if !call.isSettled, !isUnstartedSubagent(call) { awaited.append(call) }
    }
    return awaited.reversed()
  }

  public var workedItems: [WorkedItem] {
    groupedItems(workedEntries)
  }

  public var workedItemsBeforePlan: [WorkedItem] {
    guard let boundary = planBoundary else { return workedItems }
    return groupedItems(workedSlice(0..<min(boundary, entries.count)))
  }

  public var workedItemsAfterPlan: [WorkedItem] {
    guard let boundary = planBoundary else { return [] }
    return groupedItems(workedSlice(min(boundary, entries.count)..<entries.count))
  }

  private func workedSlice(_ range: Range<Int>) -> [TranscriptEntry] {
    let finalIndex = finalTextIndex
    return range.compactMap { index in
      if index == finalIndex { return nil }
      if case let .tool(call) = entries[index], call.kind == .imageGeneration { return nil }
      return entries[index]
    }
  }

  private func groupedItems(_ source: [TranscriptEntry]) -> [WorkedItem] {
    var items: [WorkedItem] = []
    var group: [ToolCall] = []
    var groupHasUnsettledCall = false
    var agents: [ToolCall] = []

    func flushAgents() {
      guard let first = agents.first else { return }
      items.append(.subagents(id: first.toolCallId, calls: agents))
      agents = []
    }

    func flushGroup() {
      guard !group.isEmpty else { return }
      items.append(
        .toolGroup(
          ToolCallGroup(
            calls: group,
            hasUnsettledCall: groupHasUnsettledCall
          )))
      group = []
      groupHasUnsettledCall = false
    }

    func flush() {
      flushAgents()
      flushGroup()
    }

    for entry in source {
      switch entry {
      case let .text(id, markdown):
        guard !entry.isBlankText else { continue }
        flush()
        items.append(.text(id: id, markdown: markdown))
      case let .tool(call) where isUnstartedSubagent(call):
        continue
      case let .tool(call) where call.kind == .agent || subagents[call.toolCallId] != nil:
        flushGroup()
        agents.append(call)
      case let .tool(call):
        flushAgents()
        if callsAfterReasoning.contains(call.toolCallId) { flushGroup() }
        group.append(call)
        groupHasUnsettledCall = groupHasUnsettledCall || !call.isSettled
      case .contextCompaction:
        continue
      }
    }
    flush()
    return items
  }

}

public enum ToolCallSummary {
  public enum Category: Equatable {
    case edit, read, search, webSearch, execute, fetch, delete, move, agent, question, other
  }

  public static func category(_ kind: ToolKind?) -> Category {
    switch kind {
    case .edit: return .edit
    case .read: return .read
    case .search: return .search
    case .webSearch: return .webSearch
    case .execute: return .execute
    case .fetch: return .fetch
    case .delete: return .delete
    case .move: return .move
    case .agent: return .agent
    case .question: return .question
    default: return .other
    }
  }

  public static func describe(_ calls: [ToolCall]) -> String {
    guard !calls.isEmpty else { return "" }
    if calls.allSatisfy(\.isIntegrationPresentationCall) {
      if calls.count == 1,
        calls[0].integrationDescription != nil || calls[0].codevisorGatewayOperation == .skills,
        let title = calls[0].integrationDisplayTitle()
      {
        return title
      }
      return calls.count == 1 ? "Used an integration tool" : "Used \(calls.count) integration tools"
    }
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
    if !calls.isEmpty, calls.allSatisfy(\.isIntegrationPresentationCall) {
      return "puzzlepiece.extension"
    }
    var counts: [Category: Int] = [:]
    for call in calls { counts[category(call.kind), default: 0] += 1 }
    let dominant = counts.max { lhs, rhs in lhs.value < rhs.value }?.key ?? .other
    switch dominant {
    case .search, .webSearch: return "magnifyingglass"
    case .execute: return "terminal"
    case .edit: return "pencil"
    case .read: return "doc.text"
    case .fetch: return "globe"
    case .delete: return "trash"
    case .move: return "arrow.right.doc.on.clipboard"
    case .agent: return "wand.and.sparkles"
    case .question: return "questionmark.bubble"
    case .other: return "wrench.and.screwdriver"
    }
  }

  public static func phrase(_ category: Category, _ count: Int) -> String {
    let single = count == 1
    switch category {
    case .read: return single ? "read a file" : "read \(count) files"
    case .search: return "searched code"
    case .webSearch: return single ? "searched the web" : "ran \(count) web searches"
    case .execute: return single ? "ran a command" : "ran \(count) commands"
    case .edit: return single ? "edited a file" : "edited \(count) files"
    case .fetch: return single ? "fetched a resource" : "fetched \(count) resources"
    case .delete: return single ? "deleted a file" : "deleted \(count) files"
    case .move: return single ? "moved a file" : "moved \(count) files"
    case .agent: return single ? "ran an agent" : "ran \(count) agents"
    case .question: return single ? "asked a question" : "asked \(count) questions"
    case .other: return single ? "ran a tool" : "ran \(count) tools"
    }
  }

  public static func join(_ phrases: [String]) -> String {
    switch phrases.count {
    case 0: return "ran tools"
    case 1: return phrases[0]
    case 2: return "\(phrases[0]) and \(phrases[1])"
    default: return phrases.dropLast().joined(separator: ", ") + ", and " + (phrases.last ?? "")
    }
  }

  public static func capitalizingFirst(_ string: String) -> String {
    guard let first = string.first else { return string }
    return first.uppercased() + string.dropFirst()
  }
}
