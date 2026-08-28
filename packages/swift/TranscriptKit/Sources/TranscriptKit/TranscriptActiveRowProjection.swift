import CodevisorProtocol

/// Builds only the live transcript slice. Callers can parse this snapshot off
/// the UI actor and splice it over the projection cache's single active slot,
/// leaving the settled transcript untouched on token flushes.
public enum TranscriptActiveRowProjection {
    public static func rows(
        for item: ConversationItem,
        waitingOnBackgroundTask: String? = nil
    ) -> [TranscriptPresentationRow] {
        TranscriptAssistantRowProjection.activeRows(
            for: item,
            waitingOnBackgroundTask: waitingOnBackgroundTask
        )
    }

    public static func replacingActiveSlot(
        in rows: [TranscriptPresentationRow],
        with activeRows: [TranscriptPresentationRow]
    ) -> [TranscriptPresentationRow] {
        guard !activeRows.isEmpty,
            let activeIndex = rows.firstIndex(where: { $0.id.isActiveRow }),
            case let .active(activeMessageID) = rows[activeIndex].id,
            activeRows.first?.id.messageID == activeMessageID
        else { return rows }
        var result = rows
        result.replaceSubrange(activeIndex...activeIndex, with: activeRows)
        return result
    }
}

extension TranscriptAssistantRowProjection {
    static func activeRows(
        for item: ConversationItem,
        waitingOnBackgroundTask: String?
    ) -> [TranscriptPresentationRow] {
        guard case let .assistant(message) = item else { return [activeFallbackRow(for: item)] }

        var rows: [TranscriptPresentationRow] = []
        let lifecycle: TranscriptBlockLifecycle =
            message.turn.isGenerating ? .receiving : .settled
        if let planDocument = message.turn.planDocument, !planDocument.isEmpty {
            let revision = measurementRevision(
                for: item,
                waitingOnBackgroundTask: waitingOnBackgroundTask
            )
            if message.turn.hasDeferredWorkedDetails || !message.turn.workedItemsBeforePlan.isEmpty {
                rows.append(
                    .init(
                        id: planningID(messageID: message.id, lifecycle: lifecycle),
                        content: .assistantPlanning(message),
                        estimatedHeight: 44,
                        measurementRevision: revision
                    ))
            }
            TranscriptPlanRowProjection.append(
                messageID: message.id,
                markdown: planDocument,
                lifecycle: lifecycle,
                to: &rows
            )
            if !appendAssistantResponse(
                message,
                prelude: .resultPrelude,
                waitingOnBackgroundTask: waitingOnBackgroundTask,
                lifecycle: lifecycle,
                to: &rows
            ),
                !message.turn.workedItemsAfterPlan.isEmpty
                    || message.turn.finalText != nil
                    || message.turn.stopDetail != nil
                    || message.turn.isGenerating
            {
                rows.append(
                    .init(
                        id: resultID(messageID: message.id, lifecycle: lifecycle),
                        content: .assistantResult(
                            message,
                            waitingOnBackgroundTask: waitingOnBackgroundTask
                        ),
                        estimatedHeight: 240,
                        measurementRevision: revision
                    ))
            }
            return rows.isEmpty ? [activeFallbackRow(for: item)] : rows
        }

        guard
            appendAssistantResponse(
                message,
                prelude: .completePrelude,
                waitingOnBackgroundTask: waitingOnBackgroundTask,
                lifecycle: lifecycle,
                to: &rows
            )
        else { return [activeFallbackRow(for: item)] }
        return rows
    }
}
