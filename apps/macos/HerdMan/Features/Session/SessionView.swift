import SwiftUI
import AppKit
import HerdManCore

/// A scroll snapshot used to tell user-initiated upward scrolling apart from
/// the transcript growing underneath a pinned viewport.
private struct ScrollSnapshot: Equatable {
    var offsetY: CGFloat
    var distance: CGFloat
}

/// The active session screen: a streaming transcript with the composer floating
/// over the bottom of the history (no divider), and enough bottom inset that the
/// last message can scroll clear of the composer.
struct SessionScreen: View {
    @Environment(\.theme) private var theme
    @Bindable var controller: SessionController
    var paneGroup: PaneGroupModel
    @State private var isAtBottom = true
    @State private var composerHeight: CGFloat = 96
    @State private var focus = TerminalFocusController()
    @State private var isQueueExpanded = true
    @State private var attachmentImages: AttachmentImageStore?
    private let bottomID = "session-bottom"

    /// Auto-follow stays engaged only while the very end of the content is in
    /// view (within this many points of the viewport bottom) — so scrolling up
    /// even slightly disengages it instantly. Kept just above zero so the
    /// rubber-band rebound after an over-scroll (which eases back into the
    /// bottom edge) doesn't briefly flash the scroll-to-bottom button.
    private static let atBottomThreshold: CGFloat = 2
    /// When scrolling back DOWN, re-engage auto-follow once within this distance
    /// of the end. Whether we *unpin* is decided by scroll direction rather than
    /// distance (see the geometry handler), so scrolling up mid-stream
    /// disengages immediately.
    private static let repinDistance: CGFloat = 40

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
        .onAppear {
            focus.paneGroup = paneGroup
            // ⌘J from inside a focused terminal routes here (the menu command
            // doesn't fire reliably while an AppKit view is first responder).
            paneGroup.requestToggle = { togglePanes() }
            // ⌘W closing the last tab collapses the group; focus returns here.
            paneGroup.requestComposerFocus = { focus.focusComposer() }
            if attachmentImages == nil {
                attachmentImages = AttachmentImageStore { [weak controller] fileId in
                    guard let controller else { throw SessionControllerError.serverUnavailable }
                    return try await controller.fileData(id: fileId)
                }
            }
        }
        .environment(\.attachmentImages, attachmentImages)
        .attachmentDropTarget(controller)
    }

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if controller.conversation.isEmpty {
                        if controller.isConnecting || controller.pendingUserText != nil {
                            optimisticStartingTurn
                        }
                        setupSection
                    }
                    ForEach(Array(controller.conversation.enumerated()), id: \.element.id) { index, item in
                        ConversationItemView(item: item)
                        // Pre-chat setup ran between the first message and the
                        // first response; keep the finished sections there.
                        if index == 0, case .user = item {
                            setupSection
                        }
                    }
                    if let error = controller.errorMessage {
                        errorBanner(error)
                    }
                    Color.clear
                        .frame(height: composerHeight + 24)
                        .id(bottomID)
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            // Open sessions at the end of the history, with no scroll animation.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: ScrollSnapshot.self) { geometry in
                ScrollSnapshot(
                    offsetY: geometry.contentOffset.y,
                    distance: geometry.contentSize.height - geometry.visibleRect.maxY
                )
            } action: { old, new in
                if new.distance <= Self.atBottomThreshold {
                    // End is in view (incl. the rubber-band rebound after an
                    // over-scroll) — stay pinned, keep the button hidden.
                    isAtBottom = true
                } else if new.offsetY < old.offsetY - 1 {
                    // Scrolled up and away from the end — disengage so we stop
                    // yanking the user back down.
                    isAtBottom = false
                } else if new.offsetY > old.offsetY, new.distance <= Self.repinDistance {
                    // Scrolling back down toward the end — re-engage auto-follow.
                    isAtBottom = true
                }
            }
            .onChange(of: streamFingerprint) { _, _ in
                // Follow the stream only while the user is pinned to the bottom;
                // never yank them down while they're reading earlier history.
                guard isAtBottom else { return }
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: composerHeight) { _, _ in
                if isAtBottom {
                    scrollToBottom(proxy, animated: false)
                }
            }
            .onChange(of: paneGroup.state.isVisible) { _, _ in
                // Toggling the panel resizes the chat area; when the user was
                // reading the latest messages, keep them pinned to the bottom
                // instead of letting the panel push the newest content out of view.
                guard isAtBottom else { return }
                scrollToBottom(proxy, animated: true)
                // Re-pin once the panel's show/hide animation has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    scrollToBottom(proxy, animated: false)
                }
            }
            .onChange(of: paneGroup.state.height) { _, _ in
                guard paneGroup.state.isVisible, isAtBottom else { return }
                scrollToBottom(proxy, animated: false)
            }
            .overlay(alignment: .bottom) {
                if !isAtBottom {
                    scrollToBottomButton(proxy)
                        .padding(.bottom, composerHeight + 4)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .overlay(alignment: .bottom) { composerOverlay }
            .animation(.snappy(duration: 0.2), value: isAtBottom)
        }
    }

    /// Toggles the pane group's content and moves keyboard focus to match
    /// (selected pane on open, composer on close).
    private func togglePanes() {
        let target = paneGroup.toggle()
        // Defer focus until SwiftUI has mounted/removed the panel.
        DispatchQueue.main.async { focus.apply(target) }
    }

    private func scrollToBottomButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            scrollToBottom(proxy, animated: true)
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Scroll to bottom")
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
        if animated {
            withAnimation(.snappy(duration: 0.18)) { action() }
        } else {
            action()
        }

        // Markdown and overlay layout can grow on the next pass while streaming;
        // a deferred scroll keeps the real bottom aligned instead of stopping a
        // few points above the latest content.
        DispatchQueue.main.async {
            if animated {
                withAnimation(.snappy(duration: 0.18)) { action() }
            } else {
                action()
            }
        }
    }

    private var composerOverlay: some View {
        VStack(spacing: 8) {
            if !controller.queuedPrompts.isEmpty {
                PromptQueueView(controller: controller, isExpanded: $isQueueExpanded)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
            ComposerCard(
                controller: controller,
                placeholder: "Ask for follow-up changes",
                onTextViewReady: { focus.composerTextView = $0 }
            )
            statusLabel
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 880)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 16)
        .padding(.top, 24)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        .animation(.snappy(duration: 0.2), value: controller.queuedPrompts.map(\.id))
        .animation(.snappy(duration: 0.2), value: isQueueExpanded)
        .background(
            LinearGradient(
                colors: [
                    theme.windowBackground.opacity(0),
                    theme.windowBackground.opacity(0.9),
                    theme.windowBackground
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        )
    }

    /// The "Setting up worktree…" / "Starting <harness>…" sections for a
    /// brand-new session: live timers and streamed logs while pre-chat setup
    /// runs, collapsing to "Set up worktree in 60s" once done.
    @ViewBuilder
    private var setupSection: some View {
        if !controller.setupPhases.isEmpty {
            SessionSetupView(phases: controller.setupPhases)
        }
    }

    @ViewBuilder
    private var optimisticStartingTurn: some View {
        // The pending prompt is held by the controller from the instant the
        // user sends (the composer is cleared immediately); fall back to the
        // composer for the pre-send connecting state.
        let text = (controller.pendingUserText
            ?? controller.composerText.trimmingCharacters(in: .whitespacesAndNewlines))
        if !text.isEmpty || !controller.pendingUserAttachments.isEmpty {
            UserMessageView(message: UserMessage(text: text, attachments: controller.pendingUserAttachments))
            // The setup sections narrate pre-chat progress with their own
            // timers; the generic shimmer only covers flows without them.
            if controller.setupPhases.isEmpty {
                ShimmeringText.startingAgent
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch controller.status {
        case .connecting:
            EmptyView()
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(theme.statusWarn)
        case .idle:
            EmptyView()
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(theme.statusError)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.statusError.opacity(0.1)))
    }

    private var streamFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(controller.conversation.count)
        if case let .assistant(message) = controller.conversation.last {
            hasher.combine(message.turn.entries.count)
            hasher.combine(message.turn.isThinking)
            if case let .text(_, markdown) = message.turn.finalText {
                hasher.combine(markdown.count)
            }
        }
        return hasher.finalize()
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
                machine: .local,
                session: session,
                project: project
            )
        }
    )
}
#endif
