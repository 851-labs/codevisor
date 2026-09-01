import CodevisorCore
import CodevisorUI
import SwiftUI
import TranscriptKit

struct TranscriptSettledWorkedItemRow: View {
    let item: TranscriptSettledWorkedItem

    var body: some View {
        TranscriptSettledWorkedItemPresentation(item: item) {
            item,
            turn,
            turnID,
            isTurnActive,
            animationPresentation,
            animationEnabled in
            TurnItemsView(
                items: [item],
                turn: turn,
                turnId: turnID,
                depth: 0,
                isTurnActive: isTurnActive,
                animationPresentation: animationPresentation,
                animationEnabled: animationEnabled
            )
        }
    }
}

struct TranscriptActiveWorkedItemRow: View {
    let controller: SessionController
    let reference: TranscriptWorkedItemReference

    var body: some View {
        TranscriptActiveWorkedItemPresentation(
            controller: controller,
            reference: reference
        ) {
            item,
            turn,
            turnID,
            isTurnActive,
            animationPresentation,
            animationEnabled in
            TurnItemsView(
                items: [item],
                turn: turn,
                turnId: turnID,
                depth: 0,
                isTurnActive: isTurnActive,
                animationPresentation: animationPresentation,
                animationEnabled: animationEnabled
            )
        }
    }
}
