import CodevisorCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

public struct TranscriptSettledWorkedHeaderRow: View {
  private let header: TranscriptWorkedSectionHeader

  public init(header: TranscriptWorkedSectionHeader) {
    self.header = header
  }

  public var body: some View {
    TranscriptWorkedSectionHeaderView(
      turn: header.message.turn,
      messageID: header.message.id,
      kind: header.kind,
      showsTimer: header.showsTimer
    )
  }
}

public struct TranscriptActiveWorkedHeaderRow: View {
  private let controller: SessionController
  private let header: TranscriptActiveWorkedSectionHeader

  public init(
    controller: SessionController,
    header: TranscriptActiveWorkedSectionHeader
  ) {
    self.controller = controller
    self.header = header
  }

  public var body: some View {
    if let model = controller.model {
      TranscriptObservedActiveWorkedHeaderRow(model: model, header: header)
    }
  }
}

public struct TranscriptSettledWorkedItemPresentation<Content: View>: View {
  private let item: TranscriptSettledWorkedItem
  private let content: TranscriptWorkedItemContent<Content>

  public init(
    item: TranscriptSettledWorkedItem,
    @ViewBuilder content: @escaping TranscriptWorkedItemContent<Content>
  ) {
    self.item = item
    self.content = content
  }

  public var body: some View {
    TranscriptWorkedItemPresentation(
      turn: item.message.turn,
      reference: item.reference,
      isTurnActive: false,
      content: content
    )
  }
}

public struct TranscriptActiveWorkedItemPresentation<Content: View>: View {
  private let controller: SessionController
  private let reference: TranscriptWorkedItemReference
  private let content: TranscriptWorkedItemContent<Content>

  public init(
    controller: SessionController,
    reference: TranscriptWorkedItemReference,
    @ViewBuilder content: @escaping TranscriptWorkedItemContent<Content>
  ) {
    self.controller = controller
    self.reference = reference
    self.content = content
  }

  public var body: some View {
    if let model = controller.model {
      TranscriptObservedActiveWorkedItemRow(
        model: model,
        reference: reference,
        content: content
      )
    }
  }
}

public typealias TranscriptWorkedItemContent<Content: View> = (
  WorkedItem,
  AssistantTurn,
  UUID,
  Bool,
  StreamingTextAnimationPresentation,
  Bool
) -> Content

/// Active worked rows live in independent native hosts. Observe the model
/// itself here: SessionController's forwarding accessors only track its stable
/// model reference, so they do not invalidate an already-mounted host when a
/// streamed tool-call snapshot changes in place.
private struct TranscriptObservedActiveWorkedHeaderRow: View {
  @Bindable var model: SessionModel
  let header: TranscriptActiveWorkedSectionHeader
  @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement

  var body: some View {
    let revision = model.activeItemRevision
    if let turn = resolvedWorkedTurn(model: model, messageID: header.messageID) {
      TranscriptWorkedSectionHeaderView(
        turn: turn,
        messageID: header.messageID,
        kind: header.kind,
        showsTimer: header.showsTimer
      )
      .onChange(of: revision, initial: true) { _, _ in
        invalidateRowMeasurement?()
      }
    }
  }
}

private struct TranscriptObservedActiveWorkedItemRow<Content: View>: View {
  @Bindable var model: SessionModel
  let reference: TranscriptWorkedItemReference
  let content: TranscriptWorkedItemContent<Content>
  @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement

  var body: some View {
    let revision = model.activeItemRevision
    if let turn = resolvedWorkedTurn(model: model, messageID: reference.messageID) {
      TranscriptWorkedItemPresentation(
        turn: turn,
        reference: reference,
        isTurnActive: turn.isGenerating,
        content: content
      )
      .onChange(of: revision, initial: true) { _, _ in
        invalidateRowMeasurement?()
      }
    }
  }
}

/// Mirrors `TranscriptActiveItemResolver` for identity-only worked rows. A
/// projection can briefly outlive the active slot as a turn settles, or keep
/// the locally-created id while the provider adopts a canonical id.
@MainActor
private func resolvedWorkedTurn(
  model: SessionModel,
  messageID: UUID
) -> AssistantTurn? {
  if case let .assistant(message)? = model.activeItem,
    message.id == messageID
  {
    return message.turn
  }
  if let settled = model.settledConversation.last(where: { $0.id == messageID }),
    case let .assistant(message) = settled
  {
    return message.turn
  }
  if case let .assistant(message)? = model.activeItem {
    return message.turn
  }
  return nil
}

private struct TranscriptWorkedItemPresentation<Content: View>: View {
  let turn: AssistantTurn
  let reference: TranscriptWorkedItemReference
  let isTurnActive: Bool
  let content: TranscriptWorkedItemContent<Content>
  @State private var animationPresentation = StreamingTextAnimationPresentation()

  var body: some View {
    let animationEnabled = prepareAnimationPresentation()
    if let item = workedItem {
      content(
        item,
        turn,
        reference.messageID,
        isTurnActive,
        animationPresentation,
        animationEnabled
      )
    }
  }

  private var workedItem: WorkedItem? {
    let items =
      switch reference.section {
      case .planning: turn.workedItemsBeforePlan
      case .implementation: turn.workedItemsAfterPlan
      }
    return items.first { $0.id == reference.itemID }
  }

  private func prepareAnimationPresentation() -> Bool {
    animationPresentation.establishBaseline(
      settling: turn,
      turnID: reference.messageID
    )
    return animationPresentation.animationsEnabled
  }
}
