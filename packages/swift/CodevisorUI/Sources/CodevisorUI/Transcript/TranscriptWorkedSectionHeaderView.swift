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
  /// Live text streams a collapsed section is hiding. Text that arrives
  /// unseen is already presented once the section opens; only what streams
  /// in while it is open should animate.
  public var hiddenStreamIDs: [String] = []
}

/// Settled transcript rows change far less often than the active turn. Keep
/// their disclosure projection out of the token-flush path while still
/// invalidating immediately for a user toggle or subagent activity change.
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

/// Removes collapsed worked-content rows before they reach the native layout
/// ledger. Headers stay mounted, while expanded sections retain ordinary
/// block-level virtualization regardless of their total length.
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

/// Stable chrome for one virtualized worked section. Its timer is intentionally
/// a plain Text driven by a small task rather than a TimelineView nested in a
/// root that may be reconciled during streaming.
public struct TranscriptWorkedSectionHeaderView: View {
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

  /// A live section shows its header from the turn's first event, before
  /// there is any work to disclose.
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
    .frame(minHeight: 18)
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

  /// Collapsed, the header stands in for the hidden work: what the turn is
  /// doing now, shimmering, then for how long. Expanded, the work is
  /// visible, so the header just times it. Once the answer is streaming the
  /// work is done, so the header already reads as settled. The subject is
  /// paced (see `WorkedActivityLabelSmoother`) so fast work doesn't flicker.
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
        // One run of text, so the label doesn't shift when the turn ends.
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

/// Worked-section labels should read as stable transcript chrome. Unlike a
/// general button, pressing or hovering the disclosure does not recolor or
/// dim its label.
public struct TranscriptWorkedSectionButtonStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
  }
}

/// Loads deferred historical work from the chevron slot. Both states occupy
/// the chevron's exact 10×10 footprint, so a network request never creates a
/// temporary transcript row or changes the header's line height.
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
    // Beside an activity, fixed-width digits keep the label from jittering
    // each second; with a prefix, the digits match the settled title.
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
  /// Sections start collapsed, live ones included: their header says what
  /// is running. Once the turn ends, a running subagent keeps its work open.
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

/// A turn's opening line before its harness's first event, including a new
/// chat's before the harness exists. Timed from the send and drawn as the
/// worked header that takes over from it, so the count never restarts.
struct TranscriptStartingWorkedHeader: View {
  let startedAt: Date
  @State private var now = Date()

  var body: some View {
    HStack(spacing: 6) {
      Text("Working for " + AssistantTurn.formatWorkedDuration(now.timeIntervalSince(startedAt)))
      Spacer(minLength: 0)
    }
    .frame(minHeight: 18)
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
