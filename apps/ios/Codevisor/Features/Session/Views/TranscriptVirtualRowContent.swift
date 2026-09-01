import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI
import TranscriptKit

/// One projected transcript row, dispatched to the shared row views.
struct TranscriptVirtualRowContent: View {
    let row: TranscriptVirtualRow
    let controller: SessionController

    var body: some View {
        switch row.content {
        case let .message(item, waitingOnBackgroundTask):
            ConversationItemRow(
                item: item,
                isWaitingOnUser: controller.pendingQuestion != nil,
                waitingOnBackgroundTask: waitingOnBackgroundTask
            )
        case let .assistantPlanning(message):
            AssistantTurnBody(
                turn: message.turn,
                turnId: message.id,
                isWaitingOnUser: controller.pendingQuestion != nil,
                presentation: .planning
            )
        case let .planDocument(markdown):
            PlanDocumentView(markdown: markdown)
        case .planHeader:
            PlanDocumentHeaderView()
        case let .assistantResult(message, waitingOnBackgroundTask):
            AssistantTurnBody(
                turn: message.turn,
                turnId: message.id,
                isWaitingOnUser: controller.pendingQuestion != nil,
                waitingOnBackgroundTask: waitingOnBackgroundTask,
                presentation: .result
            )
        case let .assistantWorkedHeader(header):
            TranscriptSettledWorkedHeaderRow(header: header)
        case let .activeWorkedHeader(header):
            TranscriptActiveWorkedHeaderRow(controller: controller, header: header)
        case let .assistantWorkedItem(item):
            TranscriptSettledWorkedItemRow(item: item)
        case let .activeWorkedItem(reference):
            TranscriptActiveWorkedItemRow(controller: controller, reference: reference)
        case let .assistantChrome(message, slice, waitingOnBackgroundTask):
            AssistantTurnBody(
                turn: message.turn,
                turnId: message.id,
                isWaitingOnUser: controller.pendingQuestion != nil,
                waitingOnBackgroundTask: waitingOnBackgroundTask,
                presentation: assistantPresentation(for: slice)
            )
        case let .markdownChunk(chunk):
            TranscriptMarkdownChunkView(chunk: chunk, streamID: row.layoutKey)
        case let .assistantAttachment(attachment):
            VStack(alignment: .leading, spacing: 4) {
                AttachmentThumbnailView(file: attachment.file, inline: true)
                Text(attachment.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .active(item):
            TranscriptActiveItemView(controller: controller, projectedItem: item)
        case let .setup(phases):
            SessionSetupView(phases: phases)
        case let .optimistic(message, showsStartingAgent):
            if !message.text.isEmpty || !message.attachments.isEmpty {
                UserBubbleRow(text: message.text, attachments: message.attachments)
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
            if row.id == .statusError {
                ChatErrorRow(
                    message,
                    actionTitle: "Retry",
                    action: { Task { await controller.retry() } }
                )
            } else {
                sessionErrorRow(message)
            }
        case let .bottomSpacer(height):
            Color.clear.frame(height: height)
        }
    }

    private func assistantPresentation(
        for slice: TranscriptAssistantChromeSlice
    ) -> AssistantTurnPresentation {
        switch slice {
        case .activity: .activity
        case .epilogue: .epilogue
        }
    }

    @ViewBuilder
    private func sessionErrorRow(_ message: String) -> some View {
        if controller.errorRequiresHarnessAuthentication {
            ChatErrorRow(
                message,
                actionTitle: "Sign In",
                action: { [weak controller] in
                    guard let controller,
                        let harnessId = controller.selectedHarnessId ?? controller.activeHarnessId
                    else { return }
                    HarnessSignInRequest(
                        serverId: controller.project.serverId, harnessId: harnessId
                    ).post()
                }
            )
        } else {
            ChatErrorRow(
                message,
                actionTitle: "Retry",
                action: { Task { await controller.retrySessionFailure() } }
            )
        }
    }
}
