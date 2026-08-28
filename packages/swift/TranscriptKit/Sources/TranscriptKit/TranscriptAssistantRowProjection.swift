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

/// One independently virtualized Markdown block. Inline semantics are already
/// resolved against the complete source snapshot by MD4C.
public struct TranscriptMarkdownBlock: Sendable, Equatable {
    public let messageID: UUID
    public let sourceID: String
    public let ordinal: Int
    public let block: MarkdownBlock
    public let documentSource: String
    public let lifecycle: TranscriptBlockLifecycle
    public let container: TranscriptMarkdownContainer

    public init(
        messageID: UUID,
        sourceID: String,
        ordinal: Int,
        block: MarkdownBlock,
        documentSource: String,
        lifecycle: TranscriptBlockLifecycle,
        container: TranscriptMarkdownContainer
    ) {
        self.messageID = messageID
        self.sourceID = sourceID
        self.ordinal = ordinal
        self.block = block
        self.documentSource = documentSource
        self.lifecycle = lifecycle
        self.container = container
    }
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
        rows.append(
            .init(
                id: .plan(message.id),
                content: .planDocument(planDocument),
                estimatedHeight: estimatedPlanHeight(planDocument),
                measurementRevision: planMeasurementRevision(planDocument)
            ))
        if !appendAssistantResponse(
            message,
            prelude: .resultPrelude,
            waitingOnBackgroundTask: waitingOnBackgroundTask,
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
    private static func appendAssistantResponse(
        _ message: AssistantMessage,
        prelude: TranscriptAssistantChromeSlice,
        waitingOnBackgroundTask: String?,
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
                for block in parser.parse(source) {
                    let projected = TranscriptMarkdownBlock(
                        messageID: message.id,
                        sourceID: sourceID,
                        ordinal: ordinal,
                        block: block,
                        documentSource: source,
                        lifecycle: .settled,
                        container: .assistantResponse
                    )
                    responseRows.append(
                        .init(
                            id: .assistantMarkdown(
                                message.id,
                                sourceID: sourceID,
                                ordinal: ordinal
                            ),
                            content: .markdownBlock(projected),
                            estimatedHeight: estimatedHeight(for: block),
                            measurementRevision: markdownMeasurementRevision(projected),
                            spacingAfter: 10
                        ))
                    ordinal += 1
                }
            case let .file(file, label):
                let attachment = TranscriptAssistantAttachment(
                    messageID: message.id,
                    sourceID: sourceID,
                    ordinal: ordinal,
                    file: file,
                    label: label,
                    lifecycle: .settled
                )
                responseRows.append(
                    .init(
                        id: .assistantAttachment(
                            message.id,
                            sourceID: sourceID,
                            ordinal: ordinal
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
                    id: .assistantChrome(message.id, prelude),
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
                id: .assistantChrome(message.id, .epilogue),
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

    private static func estimatedHeight(for block: MarkdownBlock) -> CGFloat {
        switch block {
        case let .heading(_, text), let .paragraph(text):
            max(24, min(360, 24 + CGFloat(text.characterCount / 72) * 20))
        case let .codeBlock(_, code, _):
            max(80, min(640, 52 + CGFloat(code.split(separator: "\n").count) * 18))
        case let .bulletList(items):
            max(28, CGFloat(items.count) * 26)
        case let .orderedList(items):
            max(28, CGFloat(items.count) * 26)
        case let .list(list):
            max(32, CGFloat(list.items.count) * 30)
        case let .blockQuote(blocks):
            max(36, CGFloat(blocks.count) * 34)
        case let .table(_, _, body):
            max(72, CGFloat(body.count + 1) * 34)
        case .thematicBreak:
            1
        }
    }

    private static func markdownMeasurementRevision(_ block: TranscriptMarkdownBlock) -> Int {
        var hasher = Hasher()
        hasher.combine(block.block.id)
        return hasher.finalize()
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

    private static func estimatedPlanHeight(_ markdown: String) -> CGFloat {
        max(120, min(640, 72 + CGFloat(markdown.utf8.count / 72) * 18))
    }

    private static func planMeasurementRevision(_ markdown: String) -> Int {
        var hasher = Hasher()
        hasher.combine(markdown.utf8.count)
        return hasher.finalize()
    }

    private static func measurementRevision(
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
