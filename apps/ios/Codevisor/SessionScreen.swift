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
            AssistantTurnBody(turn: message.turn, isActive: isActive)
        }
    }
}

private struct AssistantTurnBody: View {
    let turn: AssistantTurn
    let isActive: Bool

    /// Adjacent tool entries grouped into runs so consecutive calls share one
    /// ToolGroupView card, mirroring the macOS turn layout.
    private var segments: [TurnSegment] {
        var segments: [TurnSegment] = []
        for entry in turn.entries {
            switch entry {
            case let .text(id, markdown):
                segments.append(.text(id: id, markdown: markdown))
            case let .tool(call):
                if case var .tools(id, calls) = segments.last {
                    calls.append(call)
                    segments[segments.count - 1] = .tools(id: id, calls: calls)
                } else {
                    segments.append(.tools(id: "tools:\(call.toolCallId)", calls: [call]))
                }
            case let .contextCompaction(id, _):
                segments.append(.compaction(id: id))
            }
        }
        return segments
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(segments) { segment in
                switch segment {
                case let .text(_, markdown):
                    StreamingMarkdownView(markdown, isComplete: !isActive)
                case let .tools(_, calls):
                    ToolGroupView(calls: calls, isTurnActive: isActive && turn.isGenerating)
                case .compaction:
                    AgentStatusText.contextCompacted
                }
            }
            if let planDocument = turn.planDocument {
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
}

private enum TurnSegment: Identifiable {
    case text(id: String, markdown: String)
    case tools(id: String, calls: [ToolCall])
    case compaction(id: String)

    var id: String {
        switch self {
        case let .text(id, _): "text:\(id)"
        case let .tools(id, _): id
        case let .compaction(id): "compaction:\(id)"
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
