import ACPKit
import CodevisorCore
import CodevisorProtocol
import StreamMarkdown
import SwiftUI
import TranscriptKit

/// The row views whose rendering differs between AppKit and UIKit. Each
/// platform supplies these once; `TranscriptRowContentView` owns the row
/// dispatch itself so the 25-case switch has exactly one implementation.
@MainActor
public struct TranscriptRowLeaves {
    /// A settled conversation item: a user bubble or a complete assistant turn.
    public var conversationItem:
        (
            _ item: ConversationItem,
            _ isWaitingOnUser: Bool,
            _ waitingOnBackgroundTask: String?,
            _ goalActivity: GoalActivity?
        ) -> AnyView
    /// The live active item. Platforms may refresh environment values here
    /// that are otherwise frozen behind the active row's observation boundary.
    public var activeConversationItem:
        (
            _ item: ConversationItem,
            _ isWaitingOnUser: Bool,
            _ waitingOnBackgroundTask: String?,
            _ goalActivity: GoalActivity?,
            _ controller: SessionController
        ) -> AnyView
    /// One slice of a settled assistant turn.
    public var assistantTurn:
        (
            _ message: AssistantMessage,
            _ isWaitingOnUser: Bool,
            _ waitingOnBackgroundTask: String?,
            _ presentation: AssistantTurnPresentation
        ) -> AnyView
    /// An optimistic (not yet acknowledged) user message bubble.
    public var userMessage: (_ message: UserMessage) -> AnyView
    /// One worked item rendered inside a settled or active worked section.
    public var workedItem:
        (
            _ item: WorkedItem,
            _ turn: AssistantTurn,
            _ turnID: UUID,
            _ isTurnActive: Bool,
            _ animationPresentation: StreamingTextAnimationPresentation,
            _ animationEnabled: Bool
        ) -> AnyView
    /// An inline attachment thumbnail produced by the assistant.
    public var attachmentThumbnail: (_ file: PreviewFile) -> AnyView
    /// The session setup progress rows.
    public var setup: (_ phases: [SessionSetupPhase]) -> AnyView
    /// A session or status error row with its platform action.
    public var errorRow: (_ message: String, _ rowID: TranscriptPresentationRow.ID) -> AnyView

    public init(
        conversationItem: @escaping (ConversationItem, Bool, String?, GoalActivity?) -> AnyView,
        activeConversationItem:
            @escaping (ConversationItem, Bool, String?, GoalActivity?, SessionController) -> AnyView,
        assistantTurn: @escaping (AssistantMessage, Bool, String?, AssistantTurnPresentation) -> AnyView,
        userMessage: @escaping (UserMessage) -> AnyView,
        workedItem:
            @escaping (WorkedItem, AssistantTurn, UUID, Bool, StreamingTextAnimationPresentation, Bool) -> AnyView,
        attachmentThumbnail: @escaping (PreviewFile) -> AnyView,
        setup: @escaping ([SessionSetupPhase]) -> AnyView,
        errorRow: @escaping (String, TranscriptPresentationRow.ID) -> AnyView
    ) {
        self.conversationItem = conversationItem
        self.activeConversationItem = activeConversationItem
        self.assistantTurn = assistantTurn
        self.userMessage = userMessage
        self.workedItem = workedItem
        self.attachmentThumbnail = attachmentThumbnail
        self.setup = setup
        self.errorRow = errorRow
    }
}

/// One projected transcript row, dispatched to the shared row views.
public struct TranscriptRowContentView: View {
    let row: TranscriptPresentationRow
    let controller: SessionController
    let leaves: TranscriptRowLeaves

    public init(row: TranscriptPresentationRow, controller: SessionController, leaves: TranscriptRowLeaves) {
        self.row = row
        self.controller = controller
        self.leaves = leaves
    }

    public var body: some View {
        let isWaitingOnUser = controller.pendingQuestion != nil
        switch row.content {
        case let .message(item, waitingOnBackgroundTask):
            leaves.conversationItem(item, isWaitingOnUser, waitingOnBackgroundTask, nil)
        case let .assistantPlanning(message):
            leaves.assistantTurn(message, isWaitingOnUser, nil, .planning)
        case let .planDocument(markdown):
            PlanDocumentView(markdown: markdown)
        case .planHeader:
            PlanDocumentHeaderView()
        case let .assistantResult(message, waitingOnBackgroundTask):
            leaves.assistantTurn(message, isWaitingOnUser, waitingOnBackgroundTask, .result)
        case let .assistantWorkedHeader(header):
            TranscriptSettledWorkedHeaderRow(header: header)
        case let .activeWorkedHeader(header):
            TranscriptActiveWorkedHeaderRow(controller: controller, header: header)
        case let .assistantWorkedItem(item):
            TranscriptSettledWorkedItemPresentation(item: item) {
                item, turn, turnID, isTurnActive, animationPresentation, animationEnabled in
                leaves.workedItem(item, turn, turnID, isTurnActive, animationPresentation, animationEnabled)
            }
        case let .activeWorkedItem(reference):
            TranscriptActiveWorkedItemPresentation(controller: controller, reference: reference) {
                item, turn, turnID, isTurnActive, animationPresentation, animationEnabled in
                leaves.workedItem(item, turn, turnID, isTurnActive, animationPresentation, animationEnabled)
            }
        case let .assistantChrome(message, slice, waitingOnBackgroundTask):
            leaves.assistantTurn(
                message, isWaitingOnUser, waitingOnBackgroundTask, AssistantTurnPresentation(chromeSlice: slice)
            )
        case let .markdownChunk(chunk):
            TranscriptMarkdownChunkView(chunk: chunk, streamID: row.layoutKey)
        case let .assistantAttachment(attachment):
            VStack(alignment: .leading, spacing: 4) {
                leaves.attachmentThumbnail(attachment.file)
                Text(attachment.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .active(item):
            TranscriptActiveItemRow(controller: controller, projectedItem: item, leaves: leaves)
        case let .setup(phases):
            leaves.setup(phases)
        case let .optimistic(message, showsStartingAgent):
            if !message.text.isEmpty || !message.attachments.isEmpty {
                leaves.userMessage(message)
                if showsStartingAgent {
                    ShimmeringText.startingAgent
                        .suppressedDuringStreamingTextEntrance()
                }
            }
        case let .backgroundTask(description):
            ChatActivityRow("Waiting on \(description)...")
                .suppressedDuringStreamingTextEntrance()
        case let .updateGate(harnessName):
            ChatActivityRow("Waiting for \(harnessName) to finish updating...")
                .suppressedDuringStreamingTextEntrance()
        case let .connecting(message):
            ChatActivityRow(message)
                .suppressedDuringStreamingTextEntrance()
        case let .serverWait(message):
            ChatActivityRow(message)
                .suppressedDuringStreamingTextEntrance()
        case let .error(message):
            leaves.errorRow(message, row.id)
        case let .bottomSpacer(height):
            Color.clear.frame(height: height)
        }
    }
}

/// The one transcript row that re-renders on token flushes. Deliberately the
/// ONLY view whose body reads `controller.activeItem`: Observation scopes
/// invalidation to the body that read the property, so streaming updates
/// re-evaluate this subtree alone while the settled rows stay inert. Folding
/// this read into the transcript container's body would put every row back
/// on the per-flush AttributeGraph diff — the O(transcript) cost that made
/// streaming degrade with conversation length.
public struct TranscriptActiveItemRow: View {
    let controller: SessionController
    let projectedItem: ConversationItem
    let leaves: TranscriptRowLeaves
    @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement

    public init(controller: SessionController, projectedItem: ConversationItem, leaves: TranscriptRowLeaves) {
        self.controller = controller
        self.projectedItem = projectedItem
        self.leaves = leaves
    }

    public var body: some View {
        let revision = controller.activeItemRevision
        let waitingOnBackgroundTask = controller.waitingBackgroundTaskDescription
        let connectionRecoveryMessage = controller.connectionRecoveryMessage
        let goal = controller.model?.goal
        let goalActivity = goal?.status == .active ? goal?.activity : nil
        let item = TranscriptActiveItemResolver.resolve(
            projected: projectedItem,
            live: controller.activeItem,
            settled: controller.settledConversation
        )
        leaves.activeConversationItem(
            item, controller.pendingQuestion != nil, waitingOnBackgroundTask, goalActivity, controller
        )
        // The active row is hosted behind the transcript's observation
        // isolation boundary, so environment values injected by the outer
        // row factory are otherwise frozen until this row is remounted. Read
        // and inject subagent activity here so a newly active child starts
        // shimmering while its parent is still generating.
        .environment(\.runningSubagentToolCallIds, controller.runningSubagentToolCallIds)
        .id(item.id)
        .onChange(of: revision, initial: true) { _, _ in
            invalidateRowMeasurement?()
        }
        .onChange(of: waitingOnBackgroundTask) { _, _ in
            invalidateRowMeasurement?()
        }
        .onChange(of: connectionRecoveryMessage) { _, _ in
            invalidateRowMeasurement?()
        }
        .onChange(of: goalActivity) { _, _ in
            invalidateRowMeasurement?()
        }
    }
}
