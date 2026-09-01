import CoreGraphics
import Foundation
import MarkdownCore

/// The two chronological worked sections owned by an assistant turn.
public enum TranscriptWorkedSectionKind: String, Sendable, Equatable, Hashable {
    case planning
    case implementation

    var layoutComponent: String { rawValue }
}

public struct TranscriptWorkedSectionIdentity: Sendable, Equatable, Hashable {
    public let messageID: UUID
    public let kind: TranscriptWorkedSectionKind

    public init(messageID: UUID, kind: TranscriptWorkedSectionKind) {
        self.messageID = messageID
        self.kind = kind
    }
}

public enum TranscriptWorkedSectionRowRole: Sendable, Equatable {
    case header(defaultExpanded: Bool, isFixedExpanded: Bool)
    case content
}

/// Presentation metadata used to remove collapsed worked rows before they
/// enter either native virtualizer. The header remains present independently.
public struct TranscriptWorkedSectionMembership: Sendable, Equatable {
    public let identity: TranscriptWorkedSectionIdentity
    public let role: TranscriptWorkedSectionRowRole

    public init(
        identity: TranscriptWorkedSectionIdentity,
        role: TranscriptWorkedSectionRowRole
    ) {
        self.identity = identity
        self.role = role
    }
}

public struct TranscriptWorkedSectionHeader: Sendable, Equatable {
    public let message: AssistantMessage
    public let kind: TranscriptWorkedSectionKind
    public let showsTimer: Bool

    public init(
        message: AssistantMessage,
        kind: TranscriptWorkedSectionKind,
        showsTimer: Bool
    ) {
        self.message = message
        self.kind = kind
        self.showsTimer = showsTimer
    }
}

/// Identity-only active reference. Keeping live data out of this value makes
/// the header and tool-row SwiftUI roots stable across token flushes.
public struct TranscriptActiveWorkedSectionHeader: Sendable, Equatable {
    public let messageID: UUID
    public let kind: TranscriptWorkedSectionKind
    public let showsTimer: Bool

    public init(
        messageID: UUID,
        kind: TranscriptWorkedSectionKind,
        showsTimer: Bool
    ) {
        self.messageID = messageID
        self.kind = kind
        self.showsTimer = showsTimer
    }
}

public struct TranscriptWorkedItemReference: Sendable, Equatable {
    public let messageID: UUID
    public let section: TranscriptWorkedSectionKind
    public let itemID: String

    public init(
        messageID: UUID,
        section: TranscriptWorkedSectionKind,
        itemID: String
    ) {
        self.messageID = messageID
        self.section = section
        self.itemID = itemID
    }
}

public struct TranscriptSettledWorkedItem: Sendable, Equatable {
    public let message: AssistantMessage
    public let reference: TranscriptWorkedItemReference

    public init(message: AssistantMessage, reference: TranscriptWorkedItemReference) {
        self.message = message
        self.reference = reference
    }
}

extension TranscriptAssistantRowProjection {
    @discardableResult
    static func appendWorkedSection(
        _ message: AssistantMessage,
        kind: TranscriptWorkedSectionKind,
        items: [WorkedItem],
        showsTimer: Bool,
        allowsDeferred: Bool,
        lifecycle: TranscriptBlockLifecycle,
        to rows: inout [TranscriptPresentationRow]
    ) -> Bool {
        let deferredDetailID =
            allowsDeferred && message.turn.hasDeferredWorkedDetails
            ? message.turn.deferredDetailItemId
            : nil
        guard !items.isEmpty || deferredDetailID != nil else { return false }

        let identity = TranscriptWorkedSectionIdentity(messageID: message.id, kind: kind)
        let isFixedExpanded =
            message.turn.isGenerating
            && !message.turn.finalTextIsAsserted
        let defaultExpanded = isFixedExpanded
        rows.append(
            .init(
                id: workedHeaderID(
                    messageID: message.id,
                    section: kind,
                    lifecycle: lifecycle
                ),
                content: workedHeaderContent(
                    message: message,
                    kind: kind,
                    showsTimer: showsTimer,
                    lifecycle: lifecycle
                ),
                estimatedHeight: 34,
                measurementRevision: measurementRevision(
                    for: .assistant(message),
                    waitingOnBackgroundTask: nil
                ),
                spacingAfter: 12,
                workedSection: .init(
                    identity: identity,
                    role: .header(
                        defaultExpanded: defaultExpanded,
                        isFixedExpanded: isFixedExpanded
                    )
                )
            ))

        // Deferred history starts loading from the header indicator. Until
        // hydration completes there is deliberately no content row: opening
        // changes neither document geometry nor the header's line height.
        if deferredDetailID != nil {
            return true
        }

        let parser = MarkdownParser()
        for item in items {
            switch item {
            case let .text(entryID, markdown):
                let sourceID = "worked:\(kind.layoutComponent):\(entryID)"
                let blocks = parser.parse(markdown)
                for chunk in TranscriptMarkdownChunkProjection.chunks(from: blocks) {
                    let projected = TranscriptMarkdownChunk(
                        messageID: message.id,
                        sourceID: sourceID,
                        ordinal: chunk.firstOrdinal,
                        blocks: chunk.blocks,
                        documentSource: markdown,
                        lifecycle: lifecycle,
                        container: .assistantWorked,
                        fragment: chunk.fragment
                    )
                    rows.append(
                        .init(
                            id: markdownID(
                                messageID: message.id,
                                sourceID: sourceID,
                                ordinal: chunk.firstOrdinal,
                                fragment: chunk.fragment?.identity,
                                lifecycle: lifecycle
                            ),
                            content: .markdownChunk(projected),
                            estimatedHeight: projected.estimatedHeight,
                            measurementRevision: projected.measurementRevision,
                            spacingAfter: chunk.fragment?.isLastInSourceBlock == false ? 0 : 12,
                            workedSection: .init(identity: identity, role: .content)
                        ))
                }
            default:
                appendWorkedItemRow(
                    message,
                    kind: kind,
                    itemID: item.id,
                    estimatedHeight: estimatedHeight(for: item),
                    lifecycle: lifecycle,
                    identity: identity,
                    to: &rows
                )
            }
        }
        return true
    }

    private static func appendWorkedItemRow(
        _ message: AssistantMessage,
        kind: TranscriptWorkedSectionKind,
        itemID: String,
        estimatedHeight: CGFloat,
        lifecycle: TranscriptBlockLifecycle,
        identity: TranscriptWorkedSectionIdentity,
        to rows: inout [TranscriptPresentationRow]
    ) {
        let reference = TranscriptWorkedItemReference(
            messageID: message.id,
            section: kind,
            itemID: itemID
        )
        rows.append(
            .init(
                id: workedItemID(
                    messageID: message.id,
                    section: kind,
                    itemID: itemID,
                    lifecycle: lifecycle
                ),
                content: workedItemContent(
                    message: message,
                    reference: reference,
                    lifecycle: lifecycle
                ),
                estimatedHeight: estimatedHeight,
                measurementRevision: measurementRevision(
                    for: .assistant(message),
                    waitingOnBackgroundTask: nil
                ),
                spacingAfter: 12,
                workedSection: .init(identity: identity, role: .content)
            ))
    }

    private static func workedHeaderID(
        messageID: UUID,
        section: TranscriptWorkedSectionKind,
        lifecycle: TranscriptBlockLifecycle
    ) -> TranscriptPresentationRow.ID {
        switch lifecycle {
        case .receiving: .activeWorkedHeader(messageID, section)
        case .settled: .assistantWorkedHeader(messageID, section)
        }
    }

    private static func workedItemID(
        messageID: UUID,
        section: TranscriptWorkedSectionKind,
        itemID: String,
        lifecycle: TranscriptBlockLifecycle
    ) -> TranscriptPresentationRow.ID {
        switch lifecycle {
        case .receiving: .activeWorkedItem(messageID, section, itemID: itemID)
        case .settled: .assistantWorkedItem(messageID, section, itemID: itemID)
        }
    }

    private static func workedHeaderContent(
        message: AssistantMessage,
        kind: TranscriptWorkedSectionKind,
        showsTimer: Bool,
        lifecycle: TranscriptBlockLifecycle
    ) -> TranscriptPresentationRow.Content {
        switch lifecycle {
        case .receiving:
            .activeWorkedHeader(
                .init(messageID: message.id, kind: kind, showsTimer: showsTimer)
            )
        case .settled:
            .assistantWorkedHeader(
                .init(message: message, kind: kind, showsTimer: showsTimer)
            )
        }
    }

    private static func workedItemContent(
        message: AssistantMessage,
        reference: TranscriptWorkedItemReference,
        lifecycle: TranscriptBlockLifecycle
    ) -> TranscriptPresentationRow.Content {
        switch lifecycle {
        case .receiving: .activeWorkedItem(reference)
        case .settled: .assistantWorkedItem(.init(message: message, reference: reference))
        }
    }

    private static func estimatedHeight(for item: WorkedItem) -> CGFloat {
        switch item {
        case .text: 80
        case let .toolGroup(group): max(44, CGFloat(group.calls.count) * 34)
        case .contextCompaction: 24
        case .subagent: 52
        }
    }
}
