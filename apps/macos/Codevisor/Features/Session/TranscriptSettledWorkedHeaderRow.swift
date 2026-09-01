import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI
import TranscriptKit

struct TranscriptSettledWorkedHeaderRow: View {
    let header: TranscriptWorkedSectionHeader

    var body: some View {
        TranscriptWorkedSectionHeaderView(
            turn: header.message.turn,
            messageID: header.message.id,
            kind: header.kind,
            showsTimer: header.showsTimer
        )
    }
}

struct TranscriptActiveWorkedHeaderRow: View {
    let controller: SessionController
    let header: TranscriptActiveWorkedSectionHeader

    var body: some View {
        if let model = controller.model {
            TranscriptObservedActiveWorkedHeaderRow(model: model, header: header)
        }
    }
}

struct TranscriptSettledWorkedItemRow: View {
    let item: TranscriptSettledWorkedItem

    var body: some View {
        TranscriptWorkedItemBody(
            turn: item.message.turn,
            reference: item.reference,
            isTurnActive: false
        )
    }
}

struct TranscriptActiveWorkedItemRow: View {
    let controller: SessionController
    let reference: TranscriptWorkedItemReference

    var body: some View {
        if let model = controller.model {
            TranscriptObservedActiveWorkedItemRow(model: model, reference: reference)
        }
    }
}

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
        if let turn = activeTurn {
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

    private var activeTurn: AssistantTurn? {
        resolvedWorkedTurn(model: model, messageID: header.messageID)
    }
}

private struct TranscriptObservedActiveWorkedItemRow: View {
    @Bindable var model: SessionModel
    let reference: TranscriptWorkedItemReference
    @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement

    var body: some View {
        let revision = model.activeItemRevision
        if let turn = activeTurn {
            TranscriptWorkedItemBody(
                turn: turn,
                reference: reference,
                isTurnActive: turn.isGenerating
            )
            .onChange(of: revision, initial: true) { _, _ in
                invalidateRowMeasurement?()
            }
        }
    }

    private var activeTurn: AssistantTurn? {
        resolvedWorkedTurn(model: model, messageID: reference.messageID)
    }
}

/// Mirrors `TranscriptActiveItemResolver` for identity-only worked rows. A
/// projection can briefly outlive the active slot as a turn settles, or keep
/// the locally-created id while the provider adopts a canonical id.
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

private struct TranscriptWorkedItemBody: View {
    let turn: AssistantTurn
    let reference: TranscriptWorkedItemReference
    let isTurnActive: Bool
    @State private var animationPresentation = StreamingTextAnimationPresentation()

    var body: some View {
        let animationEnabled = prepareAnimationPresentation()
        if let item = workedItem {
            TranscriptItemsView(
                items: [item],
                turn: turn,
                turnID: reference.messageID,
                isTurnActive: isTurnActive,
                animationPresentation: animationPresentation,
                animationEnabled: animationEnabled
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
