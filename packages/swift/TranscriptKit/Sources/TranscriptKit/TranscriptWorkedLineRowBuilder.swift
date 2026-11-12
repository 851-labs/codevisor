import ACPKit
import CoreGraphics
import Foundation

struct TranscriptWorkedLineRowBuilder {
  private static let lineHeight: CGFloat = 26
  private static let thinkingLineHeight: CGFloat = 30

  private let messageID: UUID
  private let kind: TranscriptWorkedSectionKind
  private let lifecycle: TranscriptBlockLifecycle
  private let identity: TranscriptWorkedSectionIdentity
  private let awaitedAgents: [ToolCall]
  private let settledMeasurementRevision: Int?

  init(
    message: AssistantMessage,
    kind: TranscriptWorkedSectionKind,
    lifecycle: TranscriptBlockLifecycle,
    identity: TranscriptWorkedSectionIdentity
  ) {
    messageID = message.id
    self.kind = kind
    self.lifecycle = lifecycle
    self.identity = identity
    awaitedAgents = lifecycle == .receiving ? message.turn.awaitedAgentCalls : []
    settledMeasurementRevision = TranscriptWorkedSectionProjection.settledMeasurementRevision(
      of: message, lifecycle: lifecycle)
  }

  func earlierHistoryToggle(count: Int) -> TranscriptPresentationRow {
    row(
      itemID: WorkedItem.earlierHistoryLineID,
      content: .earlierHistory(count: count),
      isFirst: true,
      isLast: false,
      estimatedHeight: Self.lineHeight,
      role: .earlierHistoryToggle
    )
  }

  func item(
    _ item: WorkedItem,
    isFirst: Bool,
    isLast: Bool,
    role: TranscriptWorkedSectionRowRole
  ) -> TranscriptPresentationRow {
    row(
      itemID: item.id,
      content: .item(item),
      isFirst: isFirst,
      isLast: isLast,
      estimatedHeight: Self.lineHeight,
      role: role,
      awaitedAgents: awaitedAgents(in: item)
    )
  }

  func thinking(isFirst: Bool) -> TranscriptPresentationRow {
    row(
      itemID: WorkedItem.thinkingLineID,
      content: .thinking,
      isFirst: isFirst,
      isLast: true,
      estimatedHeight: Self.thinkingLineHeight,
      role: .content
    )
  }

  private func row(
    itemID: String,
    content: TranscriptWorkedLine.Content,
    isFirst: Bool,
    isLast: Bool,
    estimatedHeight: CGFloat,
    role: TranscriptWorkedSectionRowRole,
    awaitedAgents: [ToolCall] = []
  ) -> TranscriptPresentationRow {
    let line = TranscriptWorkedLine(
      reference: TranscriptWorkedItemReference(messageID: messageID, section: kind, itemID: itemID),
      content: content,
      isFirst: isFirst,
      isLast: isLast,
      isTurnActive: lifecycle == .receiving,
      awaitedAgents: awaitedAgents
    )
    return TranscriptPresentationRow(
      id: rowID(itemID: itemID),
      content: .workedLine(line),
      estimatedHeight: estimatedHeight,
      measurementRevision: settledMeasurementRevision ?? Self.revision(of: content),
      spacingAfter: isLast ? TranscriptWorkedSectionProjection.lastLineSpacingAfter : 0,
      workedSection: .init(identity: identity, role: role)
    )
  }

  private func awaitedAgents(in item: WorkedItem) -> [ToolCall] {
    guard case let .subagents(_, calls) = item else { return [] }

    return awaitedAgents.filter { awaited in calls.contains { $0.toolCallId == awaited.toolCallId } }
  }

  private func rowID(itemID: String) -> TranscriptPresentationRow.ID {
    switch lifecycle {
    case .receiving: .activeWorkedItem(messageID, kind, itemID: itemID)
    case .settled: .assistantWorkedItem(messageID, kind, itemID: itemID)
    }
  }

  private static func revision(of content: TranscriptWorkedLine.Content) -> Int {
    var hasher = Hasher()
    switch content {
    case let .item(item):
      hasher.combine(item.id)
      for call in item.calls {
        hasher.combine(call.toolCallId)
        hasher.combine(call.status)
        hasher.combine(call.stateRevision)
        hasher.combine(call.content?.count)
      }
    case .thinking:
      hasher.combine(WorkedItem.thinkingLineID)
    case let .earlierHistory(count):
      hasher.combine(count)
    }
    return hasher.finalize()
  }
}

extension WorkedItem {
  fileprivate var calls: [ToolCall] {
    switch self {
    case .text: []
    case let .toolGroup(group): group.calls
    case let .subagents(_, calls): calls
    }
  }
}
