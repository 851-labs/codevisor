import ACPKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI

/// The iOS chat screen (read path, Phase 4 first slice): connects an existing
/// session through the shared SessionController/SessionModel engine and
/// renders the transcript with the shared row views. A plain bottom-anchored
/// LazyVStack for now; the VirtualTranscriptLayout-backed virtualizer replaces
/// the scroll host as this phase completes. Composer arrives with Phase 5.
struct SessionScreen: View {
    @Environment(AppEnvironment.self) private var environment
    let sessionId: UUID

    @State private var controller: SessionController?
    @State private var missing = false

    var body: some View {
        Group {
            if let controller {
                SessionTranscriptView(controller: controller)
            } else if missing {
                ContentUnavailableView("Chat Not Found", systemImage: "questionmark.bubble")
            } else {
                ProgressView()
            }
        }
        .task { await prepare() }
    }

    private func prepare() async {
        guard controller == nil else { return }
        guard let session = environment.projectList.sessions.first(where: { $0.id == sessionId }),
              let project = environment.projectList.projects.first(where: { $0.id == session.projectId })
        else {
            missing = true
            return
        }
        let controller = SessionController(
            project: project,
            configCache: environment.configCache,
            composerDefaults: environment.composerDefaults,
            serverClient: environment.machines.client(for: session.serverId)
        )
        controller.configureExistingSession(session)
        self.controller = controller
        if session.agentSessionId?.isEmpty != false {
            // A fresh chat: no agent exists yet. Load harness capabilities so
            // the composer validates; the agent spawns on the first send.
            await controller.prepare()
            controller.applyComposerDefaults()
        }
        await controller.connectIfNeeded()
    }
}

/// The transcript body for a connected controller.
private struct SessionTranscriptView: View {
    @Bindable var controller: SessionController
    @State private var disclosure = TranscriptDisclosureStore()

    var body: some View {
        Group {
            if let model = controller.model {
                transcript(model)
            } else if case let .failed(message) = controller.status {
                ContentUnavailableView {
                    Label("Couldn't Connect", systemImage: "bolt.slash")
                } description: {
                    Text(message)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Connecting…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(controller.serverSession?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func transcript(_ model: SessionModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if model.hasOlderHistory {
                    Button {
                        Task { await model.loadOlderHistory() }
                    } label: {
                        if model.isLoadingOlderHistory {
                            ProgressView()
                        } else {
                            Text("Load Earlier")
                                .font(.footnote)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
                }

                ForEach(model.settledConversation) { item in
                    ConversationItemRow(item: item, isActive: false)
                }
                if let active = model.activeItem {
                    ConversationItemRow(item: active, isActive: true)
                }
                if controller.isLoadingInitialHistory {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
        .environment(\.transcriptDisclosure, disclosure)
        .environment(\.transcriptController, controller)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                if let question = controller.activeQuestion {
                    QuestionCardView(controller: controller, request: question)
                        .id(question.questionId)
                }
                ComposerBar(controller: controller)
            }
        }
    }
}

/// The iOS composer, first slice: always docked at the bottom of the chat
/// panel, rides the keyboard via the safe-area inset, grows with its text.
/// Attachment/model pickers and the swipe-up expanded editor arrive as
/// Phase 5 continues; send/stop already run the shared controller paths.
private struct ComposerBar: View {
    @Bindable var controller: SessionController
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Attachment entry point (photo library / camera / files) lands
            // with the attachment slice; the affordance anchors the layout.
            Button {
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(HoverIconButtonStyle(shape: .circle))
            .disabled(true)

            if let modeState = controller.modeState,
               modeState.availableModes.count > 1 {
                ModePickerChip(controller: controller, modeState: modeState)
            }

            TextField("Message the agent", text: $controller.composerText, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .padding(.vertical, 7)

            sendOrStopButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .composerGlassSurface(cornerRadius: ComposerGlassStyle.composerCornerRadius)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    @ViewBuilder private var sendOrStopButton: some View {
        if controller.isSending {
            Button {
                Task { await controller.stop() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(.white)
                    .background(Circle().fill(.red))
            }
            .buttonStyle(.plain)
        } else {
            Button {
                Task { await controller.send() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(.white)
                    .background(Circle().fill(controller.canSend ? Color.accentColor : Color.secondary.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .disabled(!controller.canSend)
        }
    }
}

/// One conversation item: a trailing user bubble or a linear assistant turn.
/// The linear rendering (text and tools in stream order) is the interim shape;
/// worked-section collapsing arrives with the full transcript port.
private struct ConversationItemRow: View {
    @Environment(\.theme) private var theme
    let item: ConversationItem
    let isActive: Bool

    var body: some View {
        switch item {
        case let .user(message):
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.attachments.isEmpty {
                        Text("\(message.attachments.count) attachment\(message.attachments.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(message.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(theme.bubbleBackground, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        case let .assistant(message):
            AssistantTurnBody(turn: message.turn, isActive: isActive, turnId: message.id)
        }
    }
}

private struct AssistantTurnBody: View {
    @Environment(\.transcriptDisclosure) private var disclosureStore
    @Environment(\.transcriptController) private var transcriptController
    let turn: AssistantTurn
    let isActive: Bool
    /// Stable identity for the turn's disclosure keys (the message id).
    let turnId: UUID

    private var isStreaming: Bool { isActive && turn.isGenerating }
    private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isStreaming {
                // Stream in strict arrival order; text and tool groups must
                // never reorder around each other mid-turn.
                ForEach(turn.streamingItems) { item in
                    workedItemView(item, dimmed: false)
                }
            } else {
                workedSection(
                    items: turn.workedItemsBeforePlan,
                    key: .turn(turnId),
                    allowsDeferred: true
                )
                if let planDocument = turn.planDocument {
                    PlanDocumentView(markdown: planDocument)
                }
                // Deferred detail hydrates through the first section only; this
                // one appears once real post-plan items exist.
                workedSection(
                    items: turn.workedItemsAfterPlan,
                    key: .turnImplementation(turnId),
                    allowsDeferred: false
                )
                if case let .text(_, markdown) = turn.finalText {
                    StreamingMarkdownView(markdown)
                }
            }
            if isStreaming, let planDocument = turn.planDocument {
                PlanDocumentView(markdown: planDocument)
            }
            if isActive, turn.showsActivityIndicator {
                ShimmeringText.thinking
            }
            if let stopDetail = turn.stopDetail {
                Label(stopDetail, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A settled "Worked" disclosure: summary line collapsed, the full
    /// reasoning/tool trail on expand — the shared reveal machinery drives the
    /// animation exactly as on macOS.
    @ViewBuilder
    private func workedSection(
        items: [WorkedItem],
        key: TranscriptDisclosureStore.Key,
        allowsDeferred: Bool
    ) -> some View {
        if !items.isEmpty || (allowsDeferred && turn.hasDeferredWorkedDetails) {
            let isExpanded = store.isExpanded(key, default: false)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(workedLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TranscriptDisclosureChevron(expanded: isExpanded)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    store.toggle(key, default: false)
                }

                TranscriptDisclosureContentReveal(isExpanded: isExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        if allowsDeferred, turn.hasDeferredWorkedDetails,
                           let itemId = turn.deferredDetailItemId,
                           let transcriptController {
                            DeferredWorkedDetails(controller: transcriptController, itemId: itemId)
                        } else {
                            ForEach(items) { item in
                                workedItemView(item, dimmed: true)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private var workedLabel: String {
        if let duration = turn.duration, duration >= 1 {
            return "Worked for \(Self.durationFormatter.string(from: duration) ?? "a moment")"
        }
        return "Worked"
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    @ViewBuilder
    private func workedItemView(_ item: WorkedItem, dimmed: Bool) -> some View {
        switch item {
        case let .text(_, markdown):
            StreamingMarkdownView(markdown, isComplete: !isStreaming)
                .opacity(dimmed ? 0.85 : 1)
        case let .toolGroup(_, calls):
            ToolGroupView(calls: calls, isTurnActive: isStreaming)
        case let .subagent(_, call):
            ToolCallRow(call: call, isTurnActive: isStreaming)
        case .contextCompaction:
            AgentStatusText.contextCompacted
        }
    }
}

/// The composer's mode chip: current mode name, tap for the mode menu —
/// switching runs the shared SessionController.setMode path.
private struct ModePickerChip: View {
    @Bindable var controller: SessionController
    let modeState: SessionModeState

    private var currentName: String {
        modeState.availableModes.first { $0.id == modeState.currentModeId }?.name
            ?? modeState.currentModeId
    }

    var body: some View {
        Menu {
            ForEach(modeState.availableModes) { mode in
                Button {
                    Task { await controller.setMode(mode.id) }
                } label: {
                    if mode.id == modeState.currentModeId {
                        Label(mode.name, systemImage: "checkmark")
                    } else if let description = mode.description, !description.isEmpty {
                        Text("\(mode.name)\n\(description)")
                    } else {
                        Text(mode.name)
                    }
                }
            }
        } label: {
            Text(currentName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

/// Historical turns arrive without their worked detail; expanding the section
/// hydrates just that turn's bounded event set through the shared controller.
private struct DeferredWorkedDetails: View {
    let controller: SessionController
    let itemId: String
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                Button("Retry loading worked details") { failed = false }
                    .font(.footnote)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading worked details…")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                .task {
                    if await !controller.loadTranscriptDetails(itemId) {
                        failed = true
                    }
                }
            }
        }
    }
}
