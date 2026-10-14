import CodevisorCore
import SwiftUI
import TranscriptKit

public struct TranscriptWorkedRowsVisibilityRevision: Equatable, Sendable {
  fileprivate let expandedSections: Set<TranscriptWorkedSectionIdentity>
}

public struct TranscriptRowSetRevision: Equatable, Sendable {
  public let sourceRevision: UInt64
  public let visibilityRevision: TranscriptWorkedRowsVisibilityRevision

  public init(
    sourceRevision: UInt64,
    visibilityRevision: TranscriptWorkedRowsVisibilityRevision
  ) {
    self.sourceRevision = sourceRevision
    self.visibilityRevision = visibilityRevision
  }
}

public struct TranscriptWorkedRowsPresentation: Sendable {
  public let rows: [TranscriptPresentationRow]
  public let visibilityRevision: TranscriptWorkedRowsVisibilityRevision
  public var hiddenStreamIDs: [String] = []
}

@MainActor
public final class TranscriptWorkedRowsVisibilityCache {
  private struct Key: Equatable {
    let sourceVersion: UInt64
    let disclosureIdentity: ObjectIdentifier
    let disclosureRevision: UInt64
    let runningSubagentRunToolCallIDs: Set<String>
  }

  private var key: Key?
  private var presentation: TranscriptWorkedRowsPresentation?

  public init() {}

  public func presentSettled(
    _ rows: [TranscriptPresentationRow],
    sourceVersion: UInt64,
    disclosure: TranscriptDisclosureStore,
    runningSubagentRunToolCallIDs: Set<String>
  ) -> TranscriptWorkedRowsPresentation {
    let currentKey = Key(
      sourceVersion: sourceVersion,
      disclosureIdentity: ObjectIdentifier(disclosure),
      disclosureRevision: disclosure.workedSectionRevision,
      runningSubagentRunToolCallIDs: runningSubagentRunToolCallIDs
    )
    if key == currentKey, let presentation { return presentation }
    let presentation = TranscriptWorkedRowsVisibility.present(
      rows,
      disclosure: disclosure,
      activeItem: nil,
      runningSubagentRunToolCallIDs: runningSubagentRunToolCallIDs
    )
    key = currentKey
    self.presentation = presentation
    return presentation
  }
}

@MainActor
public enum TranscriptWorkedRowsVisibility {
  public static func present(
    _ rows: [TranscriptPresentationRow],
    disclosure: TranscriptDisclosureStore,
    activeItem: ConversationItem?,
    runningSubagentRunToolCallIDs: Set<String>
  ) -> TranscriptWorkedRowsPresentation {
    var result: [TranscriptPresentationRow] = []
    result.reserveCapacity(rows.count)
    var expansion: [TranscriptWorkedSectionIdentity: Bool] = [:]
    var hiddenStreamIDs: [String] = []

    for row in rows {
      guard let membership = row.workedSection else {
        result.append(row)
        continue
      }
      switch membership.role {
      case let .header(defaultExpanded, _):
        let defaultsExpanded =
          turn(for: row, activeItem: activeItem).map { turn in
            turn.workedSectionDefaultsExpanded(
              membership.identity.kind,
              runningSubagentRunToolCallIDs: runningSubagentRunToolCallIDs
            )
          } ?? false
        let expanded = disclosure.isExpanded(
          membership.identity.kind.disclosureKey(
            messageID: membership.identity.messageID
          ),
          default: defaultExpanded || defaultsExpanded
        )
        expansion[membership.identity] = expanded
        result.append(row)
      case .content:
        if expansion[membership.identity] ?? true {
          result.append(row)
        } else if case let .markdownChunk(chunk) = row.content, chunk.lifecycle == .receiving {
          hiddenStreamIDs.append(chunk.animationStreamID)
        }
      }
    }

    return TranscriptWorkedRowsPresentation(
      rows: result,
      visibilityRevision: TranscriptWorkedRowsVisibilityRevision(
        expandedSections: Set(
          expansion.compactMap { identity, isExpanded in
            isExpanded ? identity : nil
          }
        )
      ),
      hiddenStreamIDs: hiddenStreamIDs
    )
  }

  private static func turn(
    for row: TranscriptPresentationRow,
    activeItem: ConversationItem?
  ) -> AssistantTurn? {
    switch row.content {
    case let .assistantWorkedHeader(header):
      header.message.turn
    case let .activeWorkedHeader(header):
      if case let .assistant(message)? = activeItem, message.id == header.messageID {
        message.turn
      } else {
        nil
      }
    default:
      nil
    }
  }
}

public struct TranscriptWorkedSectionHeaderView: View {
  static let lineHeight: CGFloat = 18

  public let turn: AssistantTurn
  public let messageID: UUID
  public let kind: TranscriptWorkedSectionKind

  @Environment(\.transcriptDisclosure) private var disclosureStore
  @Environment(\.runningSubagentRunToolCallIds) private var runningSubagentRunToolCallIDs
  @Environment(\.transcriptPerformAnchoredDisclosureChange)
  private var performAnchoredDisclosureChange
  @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement
  @State private var smoother = WorkedActivityLabelSmoother()

  public init(
    turn: AssistantTurn,
    messageID: UUID,
    kind: TranscriptWorkedSectionKind
  ) {
    self.turn = turn
    self.messageID = messageID
    self.kind = kind
  }

  public var body: some View {
    if hasContent {
      Button(action: toggle) {
        header(showsChevron: true)
          .contentShape(Rectangle())
      }
      .buttonStyle(TranscriptWorkedSectionButtonStyle())
    } else {
      header(showsChevron: false)
    }
  }

  private var hasContent: Bool {
    if turn.defersWorkedSection(kind) { return true }
    switch kind {
    case .planning: return !turn.workedItemsBeforePlan.isEmpty
    case .implementation: return !turn.workedItemsAfterPlan.isEmpty
    }
  }

  private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }

  private var disclosureKey: TranscriptDisclosureStore.Key {
    kind.disclosureKey(messageID: messageID)
  }

  private var isExpanded: Bool {
    store.isExpanded(
      disclosureKey,
      default: turn.workedSectionDefaultsExpanded(
        kind,
        runningSubagentRunToolCallIDs: runningSubagentRunToolCallIDs
      )
    )
  }

  @ViewBuilder
  private func header(showsChevron: Bool) -> some View {
    HStack(spacing: 6) {
      label
      if showsChevron {
        TranscriptWorkedDisclosureIndicator(
          expanded: isExpanded,
          deferredDetailItemID: turn.hasDeferredWorkedDetails
            ? turn.deferredDetailItemId
            : nil
        )
      }
      Spacer(minLength: 0)
    }
    .frame(minHeight: TranscriptWorkedSectionHeaderView.lineHeight)
    .font(.callout)
    .foregroundStyle(.secondary)
    .transaction { transaction in
      transaction.animation = nil
    }
  }

  @ViewBuilder
  private var label: some View {
    if turn.workedSectionTicks(kind) {
      liveLabel
    } else {
      Text(turn.workedSectionTitle(kind, now: Date()))
    }
  }

  @ViewBuilder
  private var liveLabel: some View {
    let activity = turn.workedSectionActivity
    let shown = smoother.shown ?? WorkedActivityLabelSmoother.initial(activity)
    Group {
      switch shown {
      case let .step(step) where !isExpanded:
        Text(step)
          .lineLimit(1)
          .truncationMode(.tail)
          .shimmering()
          .accessibilityLabel(step)
        TranscriptWorkingDurationLabel(turn: turn, kind: kind)
          .fixedSize()
      case .step, .pending, .starting:
        TranscriptWorkingDurationLabel(turn: turn, kind: kind, prefix: "Working for ")
      case .answering:
        TranscriptWorkingDurationLabel(turn: turn, kind: kind, prefix: "Worked for ")
      }
    }
    .onChange(of: activity, initial: true) { _, next in
      smoother.observe(next, now: Date())
    }
    .task(id: smoother.deadline) {
      guard let deadline = smoother.deadline else { return }
      try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
      guard !Task.isCancelled else { return }
      smoother.tick(now: Date())
    }
  }

  private func toggle() {
    let change = {
      store.setExpanded(disclosureKey, !isExpanded)
      invalidateRowMeasurement?()
    }
    performAnchoredDisclosureChange?(change) ?? change()
  }
}

public struct TranscriptWorkedSectionButtonStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
  }
}

public struct TranscriptWorkedDisclosureIndicator: View {
  public let expanded: Bool
  public let deferredDetailItemID: String?

  @Environment(\.transcriptController) private var transcriptController
  @State private var loadingItemID: String?

  public init(expanded: Bool, deferredDetailItemID: String?) {
    self.expanded = expanded
    self.deferredDetailItemID = deferredDetailItemID
  }

  public var body: some View {
    Group {
      if loadingItemID == deferredDetailItemID, deferredDetailItemID != nil {
        ProgressView()
          .progressViewStyle(.circular)
          .controlSize(.mini)
          .tint(.secondary)
          .accessibilityLabel("Loading worked details")
      } else {
        TranscriptDisclosureChevron(expanded: expanded)
      }
    }
    .frame(width: 10, height: 10)
    .task(id: loadRequest) {
      guard let itemID = loadRequest, let transcriptController else {
        loadingItemID = nil
        return
      }
      loadingItemID = itemID
      _ = await transcriptController.loadTranscriptDetails(itemID)
      if loadingItemID == itemID {
        loadingItemID = nil
      }
    }
  }

  private var loadRequest: String? {
    guard expanded, transcriptController != nil else { return nil }
    return deferredDetailItemID
  }
}

private struct TranscriptWorkingDurationLabel: View {
  let turn: AssistantTurn
  let kind: TranscriptWorkedSectionKind
  var prefix = ""
  @State private var now = Date()

  var body: some View {
    Text(prefix + turn.workedSectionElapsed(kind, now: now))
      .font(prefix.isEmpty ? .callout.monospacedDigit() : .callout)
      .task(id: turn.workedSectionStart(kind)) {
        now = Date()
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(1))
          guard !Task.isCancelled else { return }
          now = Date()
        }
      }
  }
}

extension AssistantTurn {
  fileprivate func workedSectionDefaultsExpanded(
    _ kind: TranscriptWorkedSectionKind,
    runningSubagentRunToolCallIDs: Set<String>
  ) -> Bool {
    !workedSectionTicks(kind) && startedRunningSubagent(runningSubagentRunToolCallIDs)
  }
}

private extension TranscriptWorkedSectionKind {
  func disclosureKey(messageID: UUID) -> TranscriptDisclosureStore.Key {
    switch self {
    case .planning: .turn(messageID)
    case .implementation: .turnImplementation(messageID)
    }
  }
}

struct TranscriptStartingWorkedHeader: View {
  let startedAt: Date
  @State private var now = Date()

  var body: some View {
    HStack(spacing: 6) {
      Text("Working for " + AssistantTurn.formatWorkedDuration(now.timeIntervalSince(startedAt)))
      Spacer(minLength: 0)
    }
    .frame(minHeight: TranscriptWorkedSectionHeaderView.lineHeight)
    .font(.callout)
    .foregroundStyle(.secondary)
    .task {
      while !Task.isCancelled {
        now = Date()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }
}
