import SwiftUI
import CodevisorCore
import ACPKit

/// The active session screen: a streaming transcript with the composer floating
/// over the bottom of the history (no divider), and enough bottom inset that the
/// last message can scroll clear of the composer.
struct SessionScreen: View {
    private static let composerBottomMargin: CGFloat = 16

    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
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
    @Namespace private var composerGlassNamespace

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
        .animation(Motion.panel(reduceMotion: reduceMotion), value: paneGroup.state.isVisible)
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
        .onChange(of: controller.todos, initial: true) { _, todos in
            guard controller.observeTodoCompletion(todos), controller.isTodosExpanded else {
                return
            }
            withAnimation(Motion.quick(reduceMotion: reduceMotion)) {
                controller.isTodosExpanded = false
            }
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
                // AppKit can publish a transient edge and its corrected final
                // edge during one layout pass. Defer the SwiftUI mutation, but
                // preserve every callback in order so the final geometry wins.
                DispatchQueue.main.async {
                    if isAtBottom != atBottom { isAtBottom = atBottom }
                }
            },
            onFollowStateChange: { follows in
                DispatchQueue.main.async {
                    if autoFollow != follows { autoFollow = follows }
                }
            },
            onNearTop: {
                Task { @MainActor in requestOlderHistoryLoad() }
            },
            onScrollViewReady: { scrollView in
                focus.transcriptView = scrollView
            }
        )
        .onChange(of: controller.userSendSignal) { _, _ in
            autoFollow = true
            scrollCommand.token &+= 1
        }
        .mask {
            ComposerTranscriptMask(
                composerSize: composerMaskSize,
                bottomInset: Self.composerBottomMargin
            )
        }
        .overlay(alignment: .bottom) { bottomChromeOverlay }
        .animation(Motion.quick(reduceMotion: reduceMotion), value: isAtBottom)
    }

    /// One container and namespace coordinate every Liquid Glass shape in the
    /// bottom functional layer, including the system-styled scroll button.
    private var bottomChromeOverlay: some View {
        GlassEffectContainer(spacing: ComposerGlassStyle.clusterSpacing) {
            ZStack(alignment: .bottom) {
                if !isAtBottom {
                    scrollToBottomButton
                        .padding(.bottom, composerHeight - 10)
                        .glassEffectID(
                            ComposerGlassElement.scrollToBottom.rawValue,
                            in: composerGlassNamespace
                        )
                        .glassEffectTransition(.matchedGeometry)
                }
                composerOverlay
            }
        }
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
        let waitingDescription = controller.waitingBackgroundTaskDescription
        let waitingAssistantID: UUID? = {
            guard !controller.hasActiveItem,
                  waitingDescription != nil,
                  case let .assistant(message)? = settled.last,
                  message.turn.finalText != nil else { return nil }
            return message.id
        }()

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
            let itemWaitingDescription = item.id == waitingAssistantID ? waitingDescription : nil
            if case let .assistant(message) = item,
               let planDocument = message.turn.planDocument, !planDocument.isEmpty {
                let revision = Self.measurementRevision(
                    for: item,
                    waitingOnBackgroundTask: itemWaitingDescription
                )
                let hasPlanningRow = message.turn.hasDeferredWorkedDetails
                    || !message.turn.workedItemsBeforePlan.isEmpty
                if hasPlanningRow {
                    result.append(.init(
                        id: .assistantPlanning(message.id),
                        content: .assistantPlanning(message),
                        estimatedHeight: 44,
                        measurementRevision: revision
                    ))
                }
                result.append(.init(
                    id: .plan(message.id),
                    content: .planDocument(planDocument),
                    estimatedHeight: Self.estimatedPlanHeight(planDocument),
                    measurementRevision: Self.planMeasurementRevision(planDocument)
                ))
                let hasResultRow = !message.turn.workedItemsAfterPlan.isEmpty
                    || message.turn.finalText != nil
                    || message.turn.stopDetail != nil
                    || message.turn.isGenerating
                if hasResultRow {
                    result.append(.init(
                        id: .assistantResult(message.id),
                        content: .assistantResult(
                            message,
                            waitingOnBackgroundTask: itemWaitingDescription
                        ),
                        estimatedHeight: 240,
                        measurementRevision: revision
                    ))
                }
            } else {
                result.append(.init(
                    id: .message(item.id),
                    content: .message(
                        item,
                        waitingOnBackgroundTask: itemWaitingDescription
                    ),
                    estimatedHeight: Self.estimatedHeight(for: item),
                    measurementRevision: Self.measurementRevision(
                        for: item,
                        waitingOnBackgroundTask: itemWaitingDescription
                    )
                ))
            }
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
        if let waitingDescription, waitingAssistantID == nil, !controller.hasActiveItem {
            result.append(.init(
                id: .backgroundTask,
                content: .backgroundTask(waitingDescription),
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

    private static func estimatedPlanHeight(_ markdown: String) -> CGFloat {
        max(120, min(640, 72 + CGFloat(markdown.utf8.count / 72) * 18))
    }

    private static func planMeasurementRevision(_ markdown: String) -> Int {
        var hasher = Hasher()
        hasher.combine(markdown.utf8.count)
        return hasher.finalize()
    }

    /// Does not walk large Markdown payloads: counts and the model's existing
    /// monotonic/fingerprint fields are enough to guard in-memory measurements.
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
            hasher.combine(turn.planDocument?.utf8.count ?? 0)
            hasher.combine(turn.stopDetail?.utf8.count ?? 0)
            hasher.combine(turn.subagentActivityFingerprint)
        }
        hasher.combine(waitingOnBackgroundTask)
        return hasher.finalize()
    }

    @ViewBuilder
    private func virtualRowContent(_ row: TranscriptVirtualRow) -> some View {
        switch row.content {
        case let .message(item, waitingOnBackgroundTask):
            ConversationItemView(
                item: item,
                isWaitingOnUser: controller.pendingQuestion != nil,
                waitingOnBackgroundTask: waitingOnBackgroundTask
            )
        case let .assistantPlanning(message):
            AssistantTurnView(
                turn: message.turn,
                turnID: message.id,
                isWaitingOnUser: controller.pendingQuestion != nil,
                presentation: .planning
            )
        case let .planDocument(markdown):
            PlanDocumentView(markdown: markdown)
        case let .assistantResult(message, waitingOnBackgroundTask):
            AssistantTurnView(
                turn: message.turn,
                turnID: message.id,
                isWaitingOnUser: controller.pendingQuestion != nil,
                waitingOnBackgroundTask: waitingOnBackgroundTask,
                presentation: .result
            )
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
        VStack(spacing: ComposerGlassStyle.clusterSpacing) {
            if let todos = controller.todos, !todos.entries.isEmpty {
                TodoPanelView(
                    plan: todos,
                    isExpanded: $controller.isTodosExpanded,
                    glassNamespace: composerGlassNamespace
                )
            }
            // Hidden while editing: the composer IS the goal UI in that mode.
            if controller.supportsGoals, !controller.isGoalEditing,
               let goal = controller.goal ?? controller.draftGoal {
                GoalBannerView(
                    controller: controller,
                    goal: goal,
                    glassNamespace: composerGlassNamespace
                )
            }
            if !controller.queuedPrompts.isEmpty {
                PromptQueueView(
                    controller: controller,
                    isExpanded: $isQueueExpanded,
                    glassNamespace: composerGlassNamespace
                )
            }
            // ComposerCard owns all of its states, including blocking agent
            // questions and plan approvals, so they share one stable glass
            // identity while the content and surface geometry change.
            ComposerCard(
                controller: controller,
                placeholder: "Ask for follow-up changes",
                onTextViewReady: { textView in
                    focus.composerTextView = textView
                    // Sidebar selection mounts a fresh session screen. Wait
                    // until its text view is attached, then move keyboard
                    // focus out of the sidebar and into the composer.
                    DispatchQueue.main.async { focus.focusComposer() }
                },
                glassNamespace: composerGlassNamespace
            )
            // Keep the transcript mask in sync as the shared composer changes
            // size between its ordinary and question content.
            .onGeometryChange(for: CGSize.self) { geometry in
                geometry.size
            } action: { size in
                composerMaskSize = size
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 880)
        .padding(.bottom, Self.composerBottomMargin)
        .padding(.top, 24)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        .animation(Motion.quick(reduceMotion: reduceMotion), value: visibleComposerGlassElements)
        .animation(Motion.quick(reduceMotion: reduceMotion), value: controller.queuedPrompts.map(\.id))
        .animation(Motion.quick(reduceMotion: reduceMotion), value: isQueueExpanded)
    }

    private var visibleComposerGlassElements: [ComposerGlassElement] {
        var elements: [ComposerGlassElement] = []
        if let todos = controller.todos, !todos.entries.isEmpty {
            elements.append(.todos)
        }
        if controller.supportsGoals, !controller.isGoalEditing,
           (controller.goal ?? controller.draftGoal) != nil {
            elements.append(.goal)
        }
        if !controller.queuedPrompts.isEmpty {
            elements.append(.queue)
        }
        elements.append(.composer)
        return elements
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
                    .help("Restart Codevisor and its server")
            } else if controller.errorRequiresHarnessAuthentication {
                Button("Open Harness Settings") {
                    SettingsRouter.shared.selectedTab = .harnesses
                    openSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open Harnesses settings to sign in")
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
        let waitingOnBackgroundTask = controller.waitingBackgroundTaskDescription
        if let item = controller.activeItem {
            ConversationItemView(
                item: item,
                isWaitingOnUser: controller.pendingQuestion != nil,
                waitingOnBackgroundTask: waitingOnBackgroundTask
            )
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
                // Like subagent activity above, the outer active-row host's
                // environment is frozen from when streaming began. Refresh
                // hover suspension here so copy affordances wake up as soon
                // as the turn ends into a background-task wait.
                .environment(\.hoverTrackingSuspended, controller.isSending)
                .id(item.id)
                .onChange(of: revision, initial: true) { _, _ in
                    invalidateRowMeasurement?()
                }
                .onChange(of: waitingOnBackgroundTask) { _, _ in
                    invalidateRowMeasurement?()
                }
        }
    }
}

private struct PromptQueueView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var controller: SessionController
    @Binding var isExpanded: Bool
    let glassNamespace: Namespace.ID
    @State private var editingQueueId: String?
    @State private var editingQueueText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Motion.quick(reduceMotion: reduceMotion)) {
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
                .transition(Motion.unfold(reduceMotion: reduceMotion))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .composerGlassSurface(
            cornerRadius: ComposerGlassStyle.accessoryCornerRadius,
            id: .queue,
            in: glassNamespace
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

/// Removes transcript pixels beneath the floating composer and its bottom
/// margin so the full card sits over the chat panel's backing surface.
private struct ComposerTranscriptMask: View {
    let composerSize: CGSize
    let bottomInset: CGFloat

    var body: some View {
        Canvas { context, size in
            var visibleArea = Path()
            visibleArea.addRect(CGRect(origin: .zero, size: size))

            if composerSize.width > 0, composerSize.height > 0 {
                let holeWidth = min(composerSize.width, size.width)
                let holeHeight = min(composerSize.height + bottomInset, size.height)
                let holeRect = CGRect(
                    x: (size.width - holeWidth) / 2,
                    y: size.height - holeHeight,
                    width: holeWidth,
                    height: holeHeight
                )
                let holeShape = UnevenRoundedRectangle(
                    topLeadingRadius: ComposerCard.cornerRadius,
                    topTrailingRadius: ComposerCard.cornerRadius
                )
                visibleArea.addPath(holeShape.path(in: holeRect))
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
