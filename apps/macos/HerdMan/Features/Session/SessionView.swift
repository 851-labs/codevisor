import SwiftUI
import HerdManCore
import ACPKit

/// The active session screen: a streaming transcript with the composer floating
/// over the bottom of the history (no divider), and enough bottom inset that the
/// last message can scroll clear of the composer.
struct SessionScreen: View {
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var controller: SessionController
    var paneGroup: PaneGroupModel
    @State private var isAtBottom = true
    @State private var autoFollow = true
    @State private var composerHeight: CGFloat = 96
    @State private var focus = TerminalFocusController()
    @State private var isQueueExpanded = true
    @State private var attachmentImages: AttachmentImageStore?
    @State private var scrollCommand = TranscriptScrollCommand()
    @State private var historyLoadTask: Task<Void, Never>?
    @State private var composerMaskSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            chatArea

            // The pane-group tab bar sits directly under the chat and stays
            // visible even when the panel content is collapsed; when open it
            // doubles as the panel's resize handle.
            PaneGroupBar(group: paneGroup, onToggle: { togglePanes() })

            if paneGroup.state.isVisible {
                PaneGroupContent(group: paneGroup)
                    .frame(height: paneGroup.state.height)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: paneGroup.state.isVisible)
        .focusedSceneValue(\.terminalToggle, TerminalToggleAction(sessionId: paneGroup.sessionId) {
            togglePanes()
        })
        // Background tasks that stream through a server-owned terminal get a
        // tab in the bottom group — a dev server is something running, not
        // something the chat is waiting on. The tab lives exactly as long as
        // the task: agent kills and completions remove it.
        .onChange(of: controller.backgroundTasks, initial: true) { _, tasks in
            paneGroup.syncAgentTerminals(
                tasks.compactMap { task in
                    task.terminalKey.map { (terminalKey: $0, name: task.description) }
                },
                pruneEnded: controller.hasBackgroundTaskSnapshot
            )
        }
        .onAppear {
            autoFollow = controller.scrollState?.isAtBottom ?? true
            isAtBottom = controller.scrollState?.isAtBottom ?? true
            focus.paneGroup = paneGroup
            // ⌘J from inside a focused terminal routes here (the menu command
            // doesn't fire reliably while an AppKit view is first responder).
            paneGroup.requestToggle = { togglePanes() }
            // ⌘W closing the last tab collapses the group; focus returns here.
            paneGroup.requestComposerFocus = { focus.focusComposer() }
            focus.startTypeToFocus()
            if attachmentImages == nil {
                attachmentImages = AttachmentImageStore { [weak controller] fileId in
                    guard let controller else { throw SessionControllerError.serverUnavailable }
                    return try await controller.fileData(id: fileId)
                }
            }
        }
        .onDisappear {
            focus.stopTypeToFocus()
            historyLoadTask?.cancel()
            historyLoadTask = nil
        }
        .environment(\.attachmentImages, attachmentImages)
        .attachmentDropTarget(controller)
    }

    private var chatArea: some View {
        NativeTranscriptView(
            rows: transcriptRows,
            initialState: controller.scrollState,
            followsLatest: autoFollow,
            hasOlderHistory: controller.hasOlderHistory,
            layoutFingerprint: dynamicTypeSize.hashValue,
            scrollCommand: scrollCommand,
            rowContent: { row in
                AnyView(
                    virtualRowContent(row)
                        .environment(\.theme, theme)
                        .environment(\.attachmentImages, attachmentImages)
                        .environment(\.hoverTrackingSuspended, controller.isSending)
                        .environment(\.transcriptDisclosure, controller.disclosure)
                        .environment(\.transcriptController, controller)
                        .environment(
                            \.runningSubagentToolCallIds,
                            controller.runningSubagentToolCallIds
                        )
                )
            },
            onViewportChange: { state in
                controller.scrollState = state
            },
            onBottomStateChange: { atBottom in
                guard isAtBottom != atBottom else { return }
                Task { @MainActor in isAtBottom = atBottom }
            },
            onFollowStateChange: { follows in
                guard autoFollow != follows else { return }
                Task { @MainActor in autoFollow = follows }
            },
            onNearTop: {
                Task { @MainActor in requestOlderHistoryLoad() }
            }
        )
        .onChange(of: controller.userSendSignal) { _, _ in
            autoFollow = true
            scrollCommand.token &+= 1
        }
        .mask {
            ComposerTranscriptMask(
                composerSize: controller.activeQuestion == nil ? composerMaskSize : .zero,
                bottomInset: 16
            )
        }
        .overlay(alignment: .bottom) {
            if !isAtBottom {
                scrollToBottomButton
                    .padding(.bottom, composerHeight - 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .overlay(alignment: .bottom) { composerOverlay }
        .animation(.snappy(duration: 0.2), value: isAtBottom)
    }

    /// Toggles the pane group's content and moves keyboard focus to match
    /// (selected pane on open, composer on close).
    private func togglePanes() {
        let target = paneGroup.toggle()
        // Defer focus until SwiftUI has mounted/removed the panel.
        DispatchQueue.main.async { focus.apply(target) }
    }

    private var scrollToBottomButton: some View {
        Button {
            autoFollow = true
            scrollCommand.token &+= 1
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help("Scroll to bottom")
    }

    private func requestOlderHistoryLoad() {
        guard historyLoadTask == nil, controller.hasOlderHistory,
              !controller.isLoadingOlderHistory else { return }
        historyLoadTask = Task { @MainActor in
            defer { historyLoadTask = nil }
            await controller.loadOlderHistory()
        }
    }

    private var transcriptRows: [TranscriptVirtualRow] {
        var result: [TranscriptVirtualRow] = []
        let settled = controller.settledConversation

        if settled.isEmpty, !controller.hasActiveItem {
            if controller.isConnecting || controller.pendingUserText != nil {
                let text = controller.pendingUserText
                    ?? controller.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = UserMessage(
                    text: text,
                    attachments: controller.pendingUserAttachments
                )
                result.append(.init(
                    id: .optimistic,
                    content: .optimistic(
                        message,
                        showsStartingAgent: controller.setupPhases.isEmpty
                    ),
                    estimatedHeight: 90
                ))
            }
            if !controller.setupPhases.isEmpty {
                result.append(.init(
                    id: .setup,
                    content: .setup(controller.setupPhases),
                    estimatedHeight: 80
                ))
            }
        }

        for (index, item) in settled.enumerated() {
            if index == 0, case .assistant = item, !controller.setupPhases.isEmpty {
                result.append(.init(
                    id: .setup,
                    content: .setup(controller.setupPhases),
                    estimatedHeight: 80
                ))
            }
            result.append(.init(
                id: .message(item.id),
                content: .message(item),
                estimatedHeight: Self.estimatedHeight(for: item),
                measurementRevision: Self.measurementRevision(for: item)
            ))
            if index == 0, case .user = item, !controller.setupPhases.isEmpty {
                result.append(.init(
                    id: .setup,
                    content: .setup(controller.setupPhases),
                    estimatedHeight: 80
                ))
            }
        }

        if settled.isEmpty, controller.hasActiveItem, !controller.setupPhases.isEmpty {
            result.append(.init(
                id: .setup,
                content: .setup(controller.setupPhases),
                estimatedHeight: 80
            ))
        }
        if controller.hasActiveItem {
            result.append(.init(id: .active, content: .active, estimatedHeight: 320))
        }
        if controller.isWaitingOnBackgroundTasks {
            let task = controller.waitingBackgroundTasks.first
            let extra = controller.waitingBackgroundTasks.count - 1
            let description = task.map {
                extra > 0 ? "\($0.description) and \(extra) more" : $0.description
            } ?? "background task"
            result.append(.init(
                id: .backgroundTask,
                content: .backgroundTask(description),
                estimatedHeight: 32
            ))
        }
        if let error = controller.errorMessage {
            result.append(.init(id: .error, content: .error(error), estimatedHeight: 56))
        }
        // Failures land in the chat history, right where the turn they broke
        // would have appeared — not detached beneath the composer (HIG: show
        // errors close to where the problem occurred).
        if case let .failed(message) = controller.status, message != controller.errorMessage {
            result.append(.init(id: .statusError, content: .error(message), estimatedHeight: 56))
        }
        result.append(.init(
            id: .bottomSpacer,
            content: .bottomSpacer(max(1, composerHeight + 24)),
            estimatedHeight: max(1, composerHeight + 24)
        ))
        return result
    }

    private static func estimatedHeight(for item: ConversationItem) -> CGFloat {
        switch item {
        case let .user(message):
            max(52, min(240, 48 + CGFloat(message.text.count / 72) * 18))
        case .assistant:
            320
        }
    }

    /// Does not walk large Markdown payloads: counts and the model's existing
    /// monotonic/fingerprint fields are enough to guard in-memory measurements.
    private static func measurementRevision(for item: ConversationItem) -> Int {
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
            hasher.combine(turn.planDocument?.utf8.count ?? 0)
            hasher.combine(turn.stopDetail?.utf8.count ?? 0)
            hasher.combine(turn.subagentActivityFingerprint)
        }
        return hasher.finalize()
    }

    @ViewBuilder
    private func virtualRowContent(_ row: TranscriptVirtualRow) -> some View {
        switch row.content {
        case let .message(item):
            ConversationItemView(item: item)
        case .active:
            TranscriptActiveItemView(controller: controller)
        case let .setup(phases):
            SessionSetupView(phases: phases)
        case let .optimistic(message, showsStartingAgent):
            if !message.text.isEmpty || !message.attachments.isEmpty {
                UserMessageView(message: message)
                if showsStartingAgent {
                    ShimmeringText.startingAgent
                }
            }
        case let .backgroundTask(description):
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ShimmeringText.waitingOnBackgroundTask(description)
                Spacer(minLength: 0)
            }
        case let .error(message):
            errorBanner(message)
        case let .bottomSpacer(height):
            Color.clear.frame(height: height)
        }
    }

    private var composerOverlay: some View {
        VStack(spacing: 8) {
            if let todos = controller.todos, !todos.entries.isEmpty {
                TodoPanelView(plan: todos, isExpanded: $controller.isTodosExpanded)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
            // Hidden while editing: the composer IS the goal UI in that mode.
            if controller.supportsGoals, !controller.isGoalEditing,
               let goal = controller.goal ?? controller.draftGoal {
                GoalBannerView(controller: controller, goal: goal)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
            if !controller.queuedPrompts.isEmpty {
                PromptQueueView(controller: controller, isExpanded: $isQueueExpanded)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
            // A blocking agent question replaces the composer with the picker
            // until it's answered or dismissed (codex CLI behavior). Both plan
            // approvals ride the same picker: Claude's ExitPlanMode question
            // from the runtime, and codex's client-side post-turn prompt.
            if let question = controller.activeQuestion {
                QuestionPickerCard(controller: controller, request: question)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            } else {
                ComposerCard(
                    controller: controller,
                    placeholder: "Ask for follow-up changes",
                    onTextViewReady: { textView in
                        focus.composerTextView = textView
                        // Sidebar selection mounts a fresh session screen. Wait
                        // until its text view is attached, then move keyboard
                        // focus out of the sidebar and into the composer.
                        DispatchQueue.main.async { focus.focusComposer() }
                    }
                )
                .onGeometryChange(for: CGSize.self) { geometry in
                    geometry.size
                } action: { size in
                    composerMaskSize = size
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 880)
        .padding(.bottom, 16)
        .padding(.top, 24)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        .animation(.snappy(duration: 0.2), value: controller.queuedPrompts.map(\.id))
        .animation(.snappy(duration: 0.2), value: isQueueExpanded)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(theme.statusError)
            Spacer(minLength: 0)
            // A dead server has one remedy: relaunching the app restarts the
            // managed server too. Offer it right where the error appears.
            if message == serverUnreachableErrorMessage {
                Button("Restart") { AppRelauncher.relaunch() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Restart HerdMan and its server")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.statusError.opacity(0.1)))
        .accessibilityElement(children: .combine)
    }
}

/// The one transcript row that re-renders on token flushes. Deliberately the
/// ONLY view whose body reads `controller.activeItem`: Observation scopes
/// invalidation to the body that read the property, so streaming updates
/// re-evaluate this subtree alone while the settled ForEach above stays
/// inert. Folding this read into the transcript container's body would put
/// every row back on the per-flush AttributeGraph diff — the O(transcript)
/// cost that made streaming degrade with conversation length.
private struct TranscriptActiveItemView: View {
    let controller: SessionController
    @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement

    var body: some View {
        let revision = controller.activeItemRevision
        if let item = controller.activeItem {
            ConversationItemView(item: item)
                // The active row is hosted behind the transcript's observation
                // isolation boundary, so environment values injected by the
                // outer row factory are otherwise frozen until this row is
                // remounted. Read and inject subagent activity here so a newly
                // active child starts shimmering while its parent is still
                // generating, not only after the parent turn settles.
                .environment(
                    \.runningSubagentToolCallIds,
                    controller.runningSubagentToolCallIds
                )
                .id(item.id)
                .onChange(of: revision, initial: true) { _, _ in
                    invalidateRowMeasurement?()
                }
        }
    }
}

private struct PromptQueueView: View {
    @Environment(\.theme) private var theme
    @Bindable var controller: SessionController
    @Binding var isExpanded: Bool
    @State private var editingQueueId: String?
    @State private var editingQueueText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("Queue")
                        .font(.caption.weight(.semibold))
                    Text(queueCountText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(controller.queuedPrompts) { item in
                        queueRow(item)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.composerBackground.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func queueRow(_ item: ServerPromptQueueItem) -> some View {
        if editingQueueId == item.id {
            HStack(spacing: 8) {
                TextField("Queued message", text: $editingQueueText)
                    .textFieldStyle(.plain)
                Button {
                    Task {
                        await controller.updateQueuedPrompt(id: item.id, text: editingQueueText)
                        editingQueueId = nil
                    }
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.plain)
                .help("Save")
                Button {
                    editingQueueId = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }
            .font(.caption)
            .padding(.vertical, 2)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .foregroundStyle(.tertiary)
                Text(item.text)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    editingQueueId = item.id
                    editingQueueText = item.text
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .help("Edit queued message")
                Button {
                    Task { await controller.deleteQueuedPrompt(id: item.id) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Remove queued message")
            }
            .font(.caption)
        }
    }

    private var queueCountText: String {
        let count = controller.queuedPrompts.count
        return count == 1 ? "1 message" : "\(count) messages"
    }
}

/// Removes transcript pixels beneath the lower half of the floating composer.
/// The transparent hole reveals the chat panel's existing backing surface, so
/// no sampled or theme-derived fill color can drift from the surrounding page.
private struct ComposerTranscriptMask: View {
    let composerSize: CGSize
    let bottomInset: CGFloat

    var body: some View {
        Canvas { context, size in
            var visibleArea = Path()
            visibleArea.addRect(CGRect(origin: .zero, size: size))

            if composerSize.width > 0, composerSize.height > 0 {
                let holeWidth = min(composerSize.width, size.width)
                let holeHeight = min(composerSize.height / 2 + bottomInset, size.height)
                visibleArea.addRect(CGRect(
                    x: (size.width - holeWidth) / 2,
                    y: size.height - holeHeight,
                    width: holeWidth,
                    height: holeHeight
                ))
            }

            context.fill(
                visibleArea,
                with: .color(.white),
                style: FillStyle(eoFill: true)
            )
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

#if DEBUG
#Preview("Conversation") {
    SessionScreen(
        controller: .preview(model: .preview()),
        paneGroup: previewPaneGroup()
    )
    .frame(width: 900, height: 680)
}

#Preview("With terminal") {
    let group = previewPaneGroup()
    group.toggle()
    return SessionScreen(controller: .preview(model: .preview()), paneGroup: group)
        .frame(width: 900, height: 680)
}

private func previewPaneGroup() -> PaneGroupModel {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/shepherd"))
    let session = ChatSession(projectId: project.id, title: "Preview")
    return PaneGroupModel(
        sessionId: session.id,
        repository: DefaultPaneGroupRepository(store: InMemoryStore()),
        makeContext: { descriptor in
            PaneContext(
                paneId: descriptor.id,
                sessionId: session.id,
                terminalKey: descriptor.terminalKey,
                attachOnly: descriptor.attachOnly,
                machine: .local,
                session: session,
                project: project
            )
        }
    )
}
#endif
