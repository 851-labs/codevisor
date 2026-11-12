import CodevisorCore
import SwiftUI
import TranscriptKit

public struct TranscriptWorkedRowsVisibilityRevision: Equatable, Sendable {
  fileprivate let expandedSections: Set<TranscriptWorkedSectionIdentity>
  fileprivate let revealedEarlierHistory: Set<TranscriptWorkedSectionIdentity>
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
  }

  private var key: Key?
  private var presentation: TranscriptWorkedRowsPresentation?

  public init() {}

  public func presentSettled(
    _ rows: [TranscriptPresentationRow],
    sourceVersion: UInt64,
    disclosure: TranscriptDisclosureStore
  ) -> TranscriptWorkedRowsPresentation {
    let currentKey = Key(
      sourceVersion: sourceVersion,
      disclosureIdentity: ObjectIdentifier(disclosure),
      disclosureRevision: disclosure.workedSectionRevision
    )
    if key == currentKey, let presentation { return presentation }
    let presentation = TranscriptWorkedRowsVisibility.present(rows, disclosure: disclosure)
    key = currentKey
    self.presentation = presentation
    return presentation
  }
}

@MainActor
public enum TranscriptWorkedRowsVisibility {
  public static func present(
    _ rows: [TranscriptPresentationRow],
    disclosure: TranscriptDisclosureStore
  ) -> TranscriptWorkedRowsPresentation {
    var result: [TranscriptPresentationRow] = []
    result.reserveCapacity(rows.count)
    var expansion: [TranscriptWorkedSectionIdentity: Bool] = [:]
    var revealedEarlierHistory: Set<TranscriptWorkedSectionIdentity> = []
    var hiddenStreamIDs: [String] = []

    for row in rows {
      guard let membership = row.workedSection else {
        result.append(row)
        continue
      }
      switch membership.role {
      case let .header(defaultExpanded, isFixedExpanded):
        let section = membership.identity
        expansion[section] = isFixedExpanded || isExpanded(section, default: defaultExpanded, in: disclosure)
        if revealsEarlierHistory(of: section, in: disclosure) { revealedEarlierHistory.insert(section) }
        result.append(row)
      case .earlierHistoryToggle, .earlierHistory, .content:
        let revealsEarlier = revealedEarlierHistory.contains(membership.identity)
        if isVisible(membership.role, revealsEarlier: revealsEarlier), expansion[membership.identity] ?? true {
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
        ),
        revealedEarlierHistory: revealedEarlierHistory
      ),
      hiddenStreamIDs: hiddenStreamIDs
    )
  }

  private static func isExpanded(
    _ section: TranscriptWorkedSectionIdentity,
    default defaultExpanded: Bool,
    in disclosure: TranscriptDisclosureStore
  ) -> Bool {
    disclosure.isExpanded(section.kind.disclosureKey(messageID: section.messageID), default: defaultExpanded)
  }

  private static func revealsEarlierHistory(
    of section: TranscriptWorkedSectionIdentity,
    in disclosure: TranscriptDisclosureStore
  ) -> Bool {
    disclosure.isExpanded(section.kind.earlierHistoryDisclosureKey(messageID: section.messageID), default: false)
  }

  private static func isVisible(_ role: TranscriptWorkedSectionRowRole, revealsEarlier: Bool) -> Bool {
    switch role {
    case .earlierHistoryToggle: !revealsEarlier
    case .earlierHistory: revealsEarlier
    case .header, .content: true
    }
  }
}

public struct TranscriptWorkedSectionHeaderView: View {
  static let lineHeight: CGFloat = 18

  public let header: TranscriptWorkedSectionHeader

  @Environment(\.transcriptDisclosure) private var disclosureStore
  @Environment(\.transcriptPerformAnchoredDisclosureChange)
  private var performAnchoredDisclosureChange
  @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement
  @State private var smoother = WorkedActivityLabelSmoother()

  public init(header: TranscriptWorkedSectionHeader) {
    self.header = header
  }

  public var body: some View {
    if header.hasContent, !header.isWorking {
      Button(action: toggle) {
        row(showsChevron: true)
          .contentShape(Rectangle())
      }
      .buttonStyle(TranscriptWorkedSectionButtonStyle())
    } else {
      row(showsChevron: false)
    }
  }

  private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }

  private var disclosureKey: TranscriptDisclosureStore.Key {
    header.kind.disclosureKey(messageID: header.messageID)
  }

  private var isExpanded: Bool {
    header.isWorking || store.isExpanded(disclosureKey, default: false)
  }

  @ViewBuilder
  private func row(showsChevron: Bool) -> some View {
    HStack(spacing: 6) {
      label
      if showsChevron {
        TranscriptWorkedDisclosureIndicator(
          expanded: isExpanded,
          deferredDetailItemID: header.deferredDetailItemID
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
    switch header.progress {
    case let .working(start, activity):
      liveLabel(start: start, activity: activity)
    case let .worked(title):
      Text(title)
    }
  }

  @ViewBuilder
  private func liveLabel(start: Date?, activity: WorkedSectionActivity) -> some View {
    let shown = smoother.shown ?? WorkedActivityLabelSmoother.initial(activity)
    Group {
      switch shown {
      case let .step(step) where !isExpanded:
        Text(step)
          .lineLimit(1)
          .truncationMode(.tail)
          .shimmering()
          .accessibilityLabel(step)
        TranscriptWorkingDurationLabel(start: start)
          .fixedSize()
      case .step, .writing, .pending, .starting:
        TranscriptWorkingDurationLabel(start: start, prefix: .working)
      case .answering:
        TranscriptWorkingDurationLabel(start: start, prefix: .worked)
      }
    }
    .modifier(WorkedActivitySmoothing(activity: activity, smoother: $smoother))
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
  enum Prefix {
    case none
    case working
    case worked
  }

  let start: Date?
  var prefix = Prefix.none
  @State private var now = Date()

  var body: some View {
    label(AssistantTurn.formatWorkedDuration(now.timeIntervalSince(start ?? now)))
      .task(id: start) {
        now = Date()
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(1))
          guard !Task.isCancelled else { return }
          now = Date()
        }
      }
  }

  @ViewBuilder
  private func label(_ elapsed: String) -> some View {
    switch prefix {
    case .none: Text(elapsed).font(.callout.monospacedDigit())
    case .working: TranscriptWorkingForLabel(elapsed: elapsed)
    case .worked: Text("Worked for " + elapsed)
    }
  }
}

struct TranscriptWorkingForLabel: View {
  let elapsed: String

  var body: some View {
    HStack(spacing: 0) {
      Text("Working for")
        .shimmering()
      Text(" " + elapsed)
        .monospacedDigit()
    }
    .accessibilityElement(children: .combine)
  }
}

extension TranscriptWorkedSectionKind {
  func disclosureKey(messageID: UUID) -> TranscriptDisclosureStore.Key {
    switch self {
    case .planning: .turn(messageID)
    case .implementation: .turnImplementation(messageID)
    }
  }

  public func earlierHistoryDisclosureKey(messageID: UUID) -> TranscriptDisclosureStore.Key {
    switch self {
    case .planning: .turnEarlierHistory(messageID)
    case .implementation: .turnImplementationEarlierHistory(messageID)
    }
  }
}

struct TranscriptStartingWorkedHeader: View {
  let startedAt: Date
  @State private var now = Date()

  var body: some View {
    HStack(spacing: 6) {
      TranscriptWorkingForLabel(elapsed: AssistantTurn.formatWorkedDuration(now.timeIntervalSince(startedAt)))
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
