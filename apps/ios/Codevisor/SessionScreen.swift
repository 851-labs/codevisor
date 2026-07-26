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
