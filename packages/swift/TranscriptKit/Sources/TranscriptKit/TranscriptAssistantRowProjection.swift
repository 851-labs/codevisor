import CoreGraphics
import CodevisorProtocol
import Foundation
import MarkdownCore

public enum TranscriptBlockLifecycle: Sendable, Equatable {
    case receiving
    case settled
}

public enum TranscriptMarkdownContainer: Sendable, Equatable {
    case assistantResponse
    case planDocument
}

public struct TranscriptAssistantAttachment: Sendable, Equatable {
    public let messageID: UUID
    public let sourceID: String
    public let ordinal: Int
    public let file: PreviewFile
    public let label: String
    public let lifecycle: TranscriptBlockLifecycle
}

public enum TranscriptAssistantChromeSlice: Sendable, Equatable {
    case completePrelude
    case resultPrelude
    case epilogue

    var layoutComponent: String {
        switch self {
        case .completePrelude: "prelude"
        case .resultPrelude: "result-prelude"
        case .epilogue: "epilogue"
        }
    }
}

enum TranscriptAssistantRowProjection {
    static func appendSettled(
        _ item: ConversationItem,
        waitingOnBackgroundTask: String?,
        to rows: inout [TranscriptPresentationRow]
    ) {
        guard case let .assistant(message) = item else {
            rows.append(
                .init(
                    id: .message(item.id),
                    content: .message(item, waitingOnBackgroundTask: waitingOnBackgroundTask),
                    estimatedHeight: estimatedHeight(for: item),
                    measurementRevision: measurementRevision(
                        for: item,
                        waitingOnBackgroundTask: waitingOnBackgroundTask
                    )
                ))
            return
        }

        guard let planDocument = message.turn.planDocument, !planDocument.isEmpty else {
            if appendAssistantResponse(
                message,
                prelude: .completePrelude,
                waitingOnBackgroundTask: waitingOnBackgroundTask,
                lifecycle: .settled,
                to: &rows
            ) {
                return
            }
            rows.append(
                .init(
                    id: .message(item.id),
                    content: .message(item, waitingOnBackgroundTask: waitingOnBackgroundTask),
                    estimatedHeight: estimatedHeight(for: item),
                    measurementRevision: measurementRevision(
                        for: item,
                        waitingOnBackgroundTask: waitingOnBackgroundTask
                    )
                ))
            return
        }

        let revision = measurementRevision(
            for: item,
            waitingOnBackgroundTask: waitingOnBackgroundTask
        )
        if message.turn.hasDeferredWorkedDetails || !message.turn.workedItemsBeforePlan.isEmpty {
            rows.append(
                .init(
                    id: .assistantPlanning(message.id),
                    content: .assistantPlanning(message),
                    estimatedHeight: 44,
                    measurementRevision: revision
                ))
        }
        TranscriptPlanRowProjection.append(
            messageID: message.id,
            markdown: planDocument,
            lifecycle: .settled,
            to: &rows
        )
        if !appendAssistantResponse(
            message,
            prelude: .resultPrelude,
            waitingOnBackgroundTask: waitingOnBackgroundTask,
            lifecycle: .settled,
            to: &rows
        ),
            !message.turn.workedItemsAfterPlan.isEmpty
                || message.turn.finalText != nil
                || message.turn.stopDetail != nil
                || message.turn.isGenerating
        {
            rows.append(
                .init(
                    id: .assistantResult(message.id),
                    content: .assistantResult(
                        message,
                        waitingOnBackgroundTask: waitingOnBackgroundTask
                    ),
                    estimatedHeight: 240,
                    measurementRevision: revision
                ))
        }
    }

    /// Splits a final response into independently measurable rows. Error-only
    /// and still-forming turns keep their ordinary assistant shell.
    @discardableResult
    static func appendAssistantResponse(
        _ message: AssistantMessage,
        prelude: TranscriptAssistantChromeSlice,
        waitingOnBackgroundTask: String?,
        lifecycle: TranscriptBlockLifecycle,
        to rows: inout [TranscriptPresentationRow]
    ) -> Bool {
        guard case let .text(entryID, markdown)? = message.turn.finalText else { return false }

        let segments = assistantMarkdownSegments(
            markdown,
            attachments: message.turn.attachments,
            includeServerPaths: true,
            includeUnreferencedAttachments: true
        )
        var responseRows: [TranscriptPresentationRow] = []
        var ordinal = 0
        let parser = MarkdownParser()
        for (segmentIndex, segment) in segments.enumerated() {
            let sourceID = "\(entryID):\(segmentIndex)"
            switch segment {
            case let .markdown(source):
                let blocks = parser.parse(source)
                let sourceOrdinal = ordinal
                for chunk in TranscriptMarkdownChunkProjection.chunks(from: blocks) {
                    let chunkOrdinal = sourceOrdinal + chunk.firstOrdinal
                    let projected = TranscriptMarkdownChunk(
                        messageID: message.id,
                        sourceID: sourceID,
                        ordinal: chunkOrdinal,
                        blocks: chunk.blocks,
                        documentSource: source,
                        lifecycle: lifecycle,
                        container: .assistantResponse,
                        fragment: chunk.fragment
                    )
                    responseRows.append(
                        .init(
                            id: markdownID(
                                messageID: message.id,
                                sourceID: sourceID,
                                ordinal: chunkOrdinal,
                                fragment: chunk.fragment?.identity,
                                lifecycle: lifecycle
                            ),
                            content: .markdownChunk(projected),
                            estimatedHeight: estimatedHeight(
                                for: chunk.blocks,
                                fragment: chunk.fragment
                            ),
                            measurementRevision: markdownMeasurementRevision(projected),
                            spacingAfter: chunk.fragment?.isLastInSourceBlock == false ? 0 : 10
                        ))
                }
                ordinal += blocks.count
            case let .file(file, label):
                let attachment = TranscriptAssistantAttachment(
                    messageID: message.id,
                    sourceID: sourceID,
                    ordinal: ordinal,
                    file: file,
                    label: label,
                    lifecycle: lifecycle
                )
                responseRows.append(
                    .init(
                        id: attachmentID(
                            messageID: message.id,
                            sourceID: sourceID,
                            ordinal: ordinal,
                            lifecycle: lifecycle
                        ),
                        content: .assistantAttachment(attachment),
                        estimatedHeight: 180,
                        measurementRevision: attachmentMeasurementRevision(attachment),
                        spacingAfter: 8
                    ))
                ordinal += 1
            }
        }
        guard !responseRows.isEmpty else { return false }

        if hasPrelude(message.turn, slice: prelude) {
            rows.append(
                .init(
                    id: chromeID(messageID: message.id, slice: prelude, lifecycle: lifecycle),
                    content: .assistantChrome(
                        message,
                        slice: prelude,
                        waitingOnBackgroundTask: nil
                    ),
                    estimatedHeight: 80,
                    measurementRevision: measurementRevision(
                        for: .assistant(message),
                        waitingOnBackgroundTask: nil
                    ),
                    spacingAfter: 14
                ))
        }
        let last = responseRows.removeLast()
        responseRows.append(
            .init(
                id: last.id,
                content: last.content,
                estimatedHeight: last.estimatedHeight,
                measurementRevision: last.measurementRevision,
                spacingAfter: 14,
                finishedResponseItemId: last.finishedResponseItemId
            ))
        rows.append(contentsOf: responseRows)
        rows.append(
            .init(
                id: chromeID(messageID: message.id, slice: .epilogue, lifecycle: lifecycle),
                content: .assistantChrome(
                    message,
                    slice: .epilogue,
                    waitingOnBackgroundTask: waitingOnBackgroundTask
                ),
                estimatedHeight: 32,
                measurementRevision: measurementRevision(
                    for: .assistant(message),
                    waitingOnBackgroundTask: waitingOnBackgroundTask
                )
            ))
        return true
    }

    static func activeFallbackRow(
        for item: ConversationItem
    ) -> TranscriptPresentationRow {
        .init(
            id: .active(item.id),
            content: .active(item),
            estimatedHeight: 320
        )
    }

    static func planningID(
        messageID: UUID,
        lifecycle: TranscriptBlockLifecycle
    ) -> TranscriptPresentationRow.ID {
        switch lifecycle {
        case .receiving: .activePlanning(messageID)
        case .settled: .assistantPlanning(messageID)
        }
    }

    static func resultID(
        messageID: UUID,
        lifecycle: TranscriptBlockLifecycle
    ) -> TranscriptPresentationRow.ID {
        switch lifecycle {
        case .receiving: .activeResult(messageID)
        case .settled: .assistantResult(messageID)
        }
    }

    private static func chromeID(
        messageID: UUID,
        slice: TranscriptAssistantChromeSlice,
        lifecycle: TranscriptBlockLifecycle
    ) -> TranscriptPresentationRow.ID {
        switch lifecycle {
        case .receiving: .activeChrome(messageID, slice)
        case .settled: .assistantChrome(messageID, slice)
        }
    }

    private static func markdownID(
        messageID: UUID,
        sourceID: String,
        ordinal: Int,
        fragment: String?,
        lifecycle: TranscriptBlockLifecycle
    ) -> TranscriptPresentationRow.ID {
        switch lifecycle {
        case .receiving:
            .activeMarkdown(
                messageID,
                sourceID: sourceID,
                ordinal: ordinal,
                fragment: fragment
            )
        case .settled:
            .assistantMarkdown(
                messageID,
                sourceID: sourceID,
                ordinal: ordinal,
                fragment: fragment
            )
        }
    }

    private static func attachmentID(
        messageID: UUID,
        sourceID: String,
        ordinal: Int,
        lifecycle: TranscriptBlockLifecycle
    ) -> TranscriptPresentationRow.ID {
        switch lifecycle {
        case .receiving: .activeAttachment(messageID, sourceID: sourceID, ordinal: ordinal)
        case .settled: .assistantAttachment(messageID, sourceID: sourceID, ordinal: ordinal)
        }
    }

    static func isUser(_ item: ConversationItem) -> Bool {
        if case .user = item { return true }
        return false
    }

    static func isAssistant(_ item: ConversationItem) -> Bool {
        if case .assistant = item { return true }
        return false
    }

    static func optimisticMeasurementRevision(
        for message: UserMessage,
        showsStartingAgent: Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(2)
        hasher.combine(message.text.utf8.count)
        hasher.combine(message.attachments.count)
        for attachment in message.attachments {
            hasher.combine(attachment.id)
            hasher.combine(attachment.sizeBytes)
        }
        hasher.combine(showsStartingAgent)
        return hasher.finalize()
    }

    private static func hasPrelude(
        _ turn: AssistantTurn,
        slice: TranscriptAssistantChromeSlice
    ) -> Bool {
        switch slice {
        case .completePrelude:
            turn.hasDeferredWorkedDetails || !turn.workedItemsBeforePlan.isEmpty
                || !turn.workedItemsAfterPlan.isEmpty || turn.showsActivityIndicator
        case .resultPrelude:
            !turn.workedItemsAfterPlan.isEmpty || turn.showsActivityIndicator
        case .epilogue:
            false
        }
    }

    private static func attachmentMeasurementRevision(
        _ attachment: TranscriptAssistantAttachment
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(attachment.file.id)
        hasher.combine(attachment.label)
        return hasher.finalize()
    }

    private static func estimatedHeight(for item: ConversationItem) -> CGFloat {
        switch item {
        case let .user(message):
            max(52, min(240, 48 + CGFloat(message.text.count / 72) * 18))
        case .assistant:
            320
        }
    }

    static func measurementRevision(
        for item: ConversationItem,
        waitingOnBackgroundTask: String?
    ) -> Int {
        var hasher = Hasher()
        switch item {
        case let .user(message):
            hasher.combine(0)
            hasher.combine(message.text.utf8.count)
            hasher.combine(message.attachments.count)
            for attachment in message.attachments {
                hasher.combine(attachment.id)
                hasher.combine(attachment.sizeBytes)
            }
        case let .assistant(message):
            let turn = message.turn
            hasher.combine(1)
            hasher.combine(turn.entries.count)
            hasher.combine(turn.isGenerating)
            hasher.combine(turn.detailRevision)
            hasher.combine(turn.hasDeferredWorkedDetails)
            hasher.combine(turn.contextCompactionStatus?.rawValue)
            hasher.combine(turn.planDocument?.utf8.count ?? 0)
            hasher.combine(turn.stopDetail?.utf8.count ?? 0)
            hasher.combine(turn.subagentActivityFingerprint)
            hasher.combine(turn.attachments.count)
            for attachment in turn.attachments {
                hasher.combine(attachment.id)
                hasher.combine(attachment.sizeBytes)
            }
        }
        hasher.combine(waitingOnBackgroundTask)
        return hasher.finalize()
    }
}

private extension TranscriptAssistantRowProjection {
    static func estimatedHeight(
        for blocks: [MarkdownBlock],
        fragment: TranscriptMarkdownFragment? = nil
    ) -> CGFloat {
        let content = TranscriptMarkdownChunkProjection.estimatedHeight(for: blocks)
        guard let fragment else { return content }
        switch fragment.trailingSpacing {
        case .none: return content
        case .block: return content + 10
        case .listItem: return content + 4
        }
    }

    static func markdownMeasurementRevision(_ chunk: TranscriptMarkdownChunk) -> Int {
        var hasher = Hasher()
        for block in chunk.blocks {
            hasher.combine(block.id)
        }
        hasher.combine(chunk.fragment)
        return hasher.finalize()
    }
}
