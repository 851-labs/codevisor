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
    /// Resolved once from the session's machine: the controller's
    /// `serverSession` is replaced by server-echoed payloads during connect,
    /// so its serverId is not a reliable lookup key later on.
    @State private var serverConfig: CodevisorServerConfig?

    var body: some View {
        Group {
            if let controller {
                SessionTranscriptView(controller: controller, serverConfig: serverConfig)
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
        serverConfig = environment.machines.machine(for: session.serverId)?.serverConfig
            ?? environment.machines.selectedMachine.serverConfig
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
    let serverConfig: CodevisorServerConfig?
    @State private var disclosure = TranscriptDisclosureStore()
    @State private var showsTerminal = false

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsTerminal = true
                } label: {
                    Image(systemName: "terminal")
                }
                .disabled(controller.serverSession == nil || serverConfig == nil)
            }
        }
        .navigationDestination(isPresented: $showsTerminal) {
            if let session = controller.serverSession, let serverConfig {
                TerminalScreen(
                    sessionId: session.id.uuidString,
                    cwd: session.cwd ?? controller.project.folderURL.path,
                    config: serverConfig
                )
            }
        }
    }

    private func transcript(_ model: SessionModel) -> some View {
        VStack(spacing: 0) {
            transcriptScroll(model)
            if let question = controller.activeQuestion {
                QuestionCardView(controller: controller, request: question)
                    .id(question.questionId)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            ComposerBar(controller: controller)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func transcriptScroll(_ model: SessionModel) -> some View {
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
        .environment(\.transcriptDisclosure, disclosure)
        .environment(\.transcriptController, controller)
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
