import SwiftUI
import AppKit
import HerdManCore

/// The active session screen: a streaming transcript with the composer floating
/// over the bottom of the history (no divider), and enough bottom inset that the
/// last message can scroll clear of the composer.
struct SessionScreen: View {
    @Bindable var controller: SessionController
    var terminal: TerminalSession
    @State private var isAtBottom = true
    @State private var composerHeight: CGFloat = 96
    @State private var focus = TerminalFocusController()
    @State private var isQueueExpanded = true
    private let bottomID = "session-bottom"

    var body: some View {
        VStack(spacing: 0) {
            chatArea

            // The status bar sits directly under the chat; when the panel is
            // open it becomes the panel's top bar / resize handle.
            SessionStatusBar(controller: controller, terminal: terminal, onToggle: { toggleTerminal() })

            if terminal.panel.isVisible {
                TerminalPanel(session: terminal)
                    .frame(height: terminal.panel.height)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: terminal.panel.isVisible)
        .focusedSceneValue(\.terminalToggle, TerminalToggleAction(sessionId: terminal.id) {
            toggleTerminal()
        })
        .onAppear { focus.terminal = terminal }
    }

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if controller.conversation.isEmpty, controller.isConnecting {
                        optimisticStartingTurn
                    }
                    ForEach(controller.conversation) { item in
                        ConversationItemView(item: item)
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
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                // Distance from the visible bottom to the end of the content.
                geometry.contentSize.height - geometry.visibleRect.maxY
            } action: { _, distance in
                isAtBottom = distance <= 18
            }
            .onChange(of: streamFingerprint) { _, _ in
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: composerHeight) { _, _ in
                if isAtBottom {
                    scrollToBottom(proxy, animated: false)
                }
            }
            .onChange(of: terminal.panel.isVisible) { _, _ in
                // Toggling the terminal resizes the chat area; when the user was
                // reading the latest messages, keep them pinned to the bottom
                // instead of letting the panel push the newest content out of view.
                guard isAtBottom else { return }
                scrollToBottom(proxy, animated: true)
                // Re-pin once the panel's show/hide animation has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    scrollToBottom(proxy, animated: false)
                }
            }
            .onChange(of: terminal.panel.height) { _, _ in
                guard terminal.panel.isVisible, isAtBottom else { return }
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

    /// Toggles the terminal panel and moves keyboard focus to match (terminal on
    /// open, composer on close).
    private func toggleTerminal() {
        let target = terminal.togglePanel()
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
                    Color(nsColor: .windowBackgroundColor).opacity(0),
                    Color(nsColor: .windowBackgroundColor).opacity(0.9),
                    Color(nsColor: .windowBackgroundColor)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        )
    }

    @ViewBuilder
    private var optimisticStartingTurn: some View {
        let text = controller.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            UserMessageView(message: UserMessage(text: text))
            ShimmeringText.startingAgent
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
                .foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.red.opacity(0.1)))
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
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.96))
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
        terminal: TerminalSession(id: UUID(), descriptor: previewTerminalDescriptor())
    )
    .frame(width: 900, height: 680)
}

#Preview("With terminal") {
    let terminal = TerminalSession(id: UUID(), descriptor: previewTerminalDescriptor())
    terminal.panel.isVisible = true
    return SessionScreen(controller: .preview(model: .preview()), terminal: terminal)
        .frame(width: 900, height: 680)
}

private func previewTerminalDescriptor() -> TerminalLaunchDescriptor {
    let workspace = Workspace(name: "shepherd", folderURL: URL(fileURLWithPath: "/tmp/shepherd"))
    let session = ChatSession(workspaceId: workspace.id, title: "Preview")
    return TerminalLaunchDescriptor.make(session: session, workspace: workspace, machine: .local)
}
#endif
