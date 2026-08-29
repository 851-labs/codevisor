import SwiftUI
import AppKit
import CodevisorCore
import ACPKit
import CodevisorUI

extension EnvironmentValues {
    /// True while an app self-update or a selected-server update is installing.
    /// Injected at the root; the composer reads it to lock its submit action so
    /// no new turn starts while the app/server is about to restart.
    @Entry var isAppUpdateInProgress: Bool = false
}

/// The chat composer card: a multiline input (Return sends, Shift+Return adds a
/// newline) with an inline toolbar holding the combined model dropdown
/// (models grouped by harness plus every model-owned setting), active modes,
/// and a send button.
struct ComposerCard: View {
    static let cornerRadius = ComposerGlassStyle.composerCornerRadius

    @Bindable var controller: SessionController
    var placeholder: String = "Do anything"
    /// Surfaces the composer's text view so keyboard handoffs can move
    /// first-responder focus to it.
    var onTextViewReady: ((SubmittingTextView) -> Void)? = nil
    /// The session's AppKit focus controller and this chat's id: the
    /// question picker registers its key anchor under them so it takes
    /// first responder through the same reliable path as the composer text
    /// view. Nil (previews, standalone composers) degrades to a local grab.
    var focus: TerminalFocusController? = nil
    var focusChatId: UUID? = nil
    /// Supplied by the session's shared GlassEffectContainer. Standalone
    /// composers (new chat and previews) don't need coordinated identities.
    var glassNamespace: Namespace.ID? = nil

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Locks the submit action while an app/server update is installing so no
    /// new turn starts during the restart. Defaults to false (e.g. previews).
    @Environment(\.isAppUpdateInProgress) private var isAppUpdateInProgress
    // Match ChatInputEditor's first TextKit measurement so switching sessions
    // never shows the shorter pre-measurement card for a frame.
    @State private var editorHeight: CGFloat = ChatInputEditor.singleLineHeight
    /// The editor's caret/selection, synced from AppKit. The slash palette
    /// keys off the token at the caret, so it triggers mid-message too.
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var slashSelection = 0
    @State private var isSlashMenuDismissed = false
    @State private var slashMenuContentHeight: CGFloat = 0
    @State private var isStopButtonHovered = false
    @State private var isGoalBackButtonHovered = false
    /// Owned by the shared composer shell so the question state can provide
    /// immediate submission feedback before the controller's async flag flips.
    @State private var didStartResolvingQuestion = false

    /// Tallest the slash-command menu can grow before it scrolls (~6 rows).
    private static let slashMenuMaxHeight: CGFloat = 220

    /// The palette's rendered height: its measured content, capped at the
    /// scrolling maximum. Drives both its scroll frame and its lift above
    /// the composer card.
    private var paletteHeight: CGFloat {
        if isLoadingSlashCommands, slashMenuContentHeight == 0 { return 40 }
        return min(slashMenuContentHeight, Self.slashMenuMaxHeight)
    }

    var body: some View {
        ZStack {
            if let question = controller.activeQuestion {
                QuestionPickerContent(
                    controller: controller,
                    request: question,
                    didStartResolving: $didStartResolvingQuestion,
                    focus: focus,
                    chatId: focusChatId
                )
                .transition(Motion.unfold(reduceMotion: reduceMotion, anchor: .bottom))
            } else {
                standardContent
                    .transition(Motion.unfold(reduceMotion: reduceMotion, anchor: .bottom))
            }
        }
        .padding(12)
        // Every composer state shares this one functional Liquid Glass layer.
        // State-specific content must not recreate the card background.
        .composerGlassSurface(
            cornerRadius: Self.cornerRadius,
            id: .composer,
            in: glassNamespace
        )
        // The palette floats over the transcript as its own transient Liquid
        // Glass surface (HIG: ephemeral overlays get their own glass layer)
        // and blooms up from the input with the standard quick unfold.
        // Anchored to the finished card: full card width, with its bottom
        // held one cluster gap above the card's top edge so it never overlaps
        // the composer glass.
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                if controller.activeQuestion == nil, showsSlashCommandPopup {
                    ComposerSlashCommandPopup(
                        isLoading: isLoadingSlashCommands,
                        matches: visibleSlashMatches,
                        selectedIndex: slashSelection,
                        height: paletteHeight,
                        onContentHeightChange: { slashMenuContentHeight = $0 },
                        onSelect: acceptSlashCommand
                    )
                    .transition(Motion.unfold(reduceMotion: reduceMotion, anchor: .bottom))
                }
            }
            // Lift the palette's own (measured) height plus one cluster gap
            // above the card's top edge so it never overlaps the composer.
            .offset(y: -(paletteHeight + ComposerGlassStyle.clusterSpacing))
            .animation(
                Motion.quick(reduceMotion: reduceMotion),
                value: !showsSlashCommandPopup
            )
        }
        .overlay {
            if controller.activeQuestion != nil, isQuestionResolving {
                ZStack {
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .fill(theme.windowBackground.opacity(0.72))
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Submitting response…")
                            .font(.callout.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Submitting response")
            }
        }
        .animation(
            Motion.quick(reduceMotion: reduceMotion),
            value: controller.activeQuestion?.questionId
        )
        .onChange(of: controller.activeQuestion?.questionId) { _, _ in
            didStartResolvingQuestion = false
        }
        .onChange(of: slashQuery) { _, _ in
            // A new query invalidates both the keyboard selection and any
            // Escape-dismissal of the previous menu.
            slashSelection = 0
            isSlashMenuDismissed = false
        }
    }
}

private extension ComposerCard {
    private var standardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The attachment strip sits tight against the input, closer than
            // the card's usual element spacing.
            VStack(alignment: .leading, spacing: 4) {
                if controller.isGoalEditing {
                    HStack(spacing: 6) {
                        Image(systemName: "target")
                            .font(.caption)
                        Text("Edit goal")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                if !controller.composerAttachments.isEmpty {
                    ComposerAttachmentRow(controller: controller)
                }

                ZStack(alignment: .topLeading) {
                    ChatInputEditor(
                        text: $controller.composerText,
                        calculatedHeight: $editorHeight,
                        selection: $selection,
                        onSubmit: submitOrAcceptSlash,
                        onKeyCommand: handleKeyCommand,
                        onPasteAttachments: handlePastedAttachments,
                        onTextViewReady: onTextViewReady
                    )
                    .frame(height: editorHeight)
                    .writingToolsAffordanceVisibility(.hidden)
                    // Frozen while a send is being accepted (the moment before
                    // the session page opens; the send button spins instead)
                    // and while an update is installing (the app/server is
                    // about to restart).
                    .disabled(
                        controller.isSubmitting
                            || controller.isResolvingQuestion
                            || isAppUpdateInProgress
                    )

                    if controller.composerText.isEmpty {
                        Text(controller.isGoalComposerArmed ? "Describe the goal" : placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                    }
                }
            }

            HStack(spacing: 10) {
                if controller.isGoalEditing {
                    // Editing a goal strips the chrome down to back + send;
                    // plain ⌖-armed goal setting keeps the normal toolbar.
                    Text("esc to cancel")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        goalEditBackButton
                        sendButton
                    }
                } else {
                    attachButton
                    ModelConfigMenu(controller: controller)
                    // Active modes show as removable chips (turned on via
                    // the /plan and /goal slash commands).
                    if controller.hasPlanMode, controller.isPlanModeOn {
                        ModeChip(
                            label: "Plan",
                            systemImage: "map",
                            isRemoveDisabled: controller.isPlanModeUpdatePending
                        ) {
                            Task { await controller.togglePlanMode() }
                        }
                    }
                    if controller.canEditGoal, controller.isGoalComposerArmed {
                        ModeChip(label: "Goal", systemImage: "target") {
                            withAnimation(.snappy(duration: 0.15)) { controller.exitGoalComposer() }
                        }
                    }
                    Spacer(minLength: 0)
                    // Action buttons cluster tighter than the picker chips.
                    // While the agent runs, stop takes the send slot; a draft
                    // in the composer brings send back with stop beside it.
                    HStack(spacing: 4) {
                        /* Usage gauge and popover are temporarily disabled.
                        UsageRingButton(
                            usage: controller.usage,
                            limits: controller.usageLimits,
                            isLoadingLimits: controller.isLoadingUsageLimits,
                            limitsError: controller.usageLimitsError,
                            onRequestLimits: { await controller.loadUsageLimits() }
                        )
                        */
                        if controller.isSending, !hasComposerDraft {
                            stopButton
                        } else {
                            stopButton
                            sendButton
                        }
                    }
                }
            }
            .font(.callout)
        }
    }

    private var isQuestionResolving: Bool {
        didStartResolvingQuestion || controller.isResolvingQuestion
    }

    /// Leaves edit-goal mode without changing the goal (the banner returns).
    private var goalEditBackButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) { controller.exitGoalComposer() }
        } label: {
            Image(systemName: "arrow.left")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .foregroundStyle(Color.primary)
                // Same quiet brighten-on-hover as the other filled buttons.
                .background(Circle().fill(Color.secondary.opacity(isGoalBackButtonHovered ? 0.22 : 0.16)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isGoalBackButtonHovered = $0 }
        .help("Back — keep the current goal (esc)")
        .accessibilityLabel("Back")
        .accessibilityHint("Keep the current goal. Keyboard shortcut: Escape")
    }

    private func chipLabel(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
    }

    private var attachButton: some View {
        Button {
            presentOpenPanel()
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverIconButtonStyle())
        .help("Attach files")
        .accessibilityLabel("Attach files")
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        controller.attachFileURLs(panel.urls)
    }

    /// Whether the composer holds something sendable (text or attachments).
    private var hasComposerDraft: Bool {
        !controller.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !controller.composerAttachments.isEmpty
    }

    private func handlePastedAttachments(_ pasted: [PastedAttachment]) -> Bool {
        guard !pasted.isEmpty else { return false }
        for item in pasted {
            switch item {
            case let .fileURL(url):
                controller.attachFileURLs([url])
            case let .image(data, suggestedName):
                controller.attachImageData(data, suggestedName: suggestedName)
            }
        }
        return true
    }

    @ViewBuilder
    private var stopButton: some View {
        if controller.isSending {
            if controller.isCancelling {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 26, height: 26)
                    .help("Stopping…")
            } else {
                Button {
                    Task { await controller.stop() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(isStopButtonHovered ? Color.primary.opacity(0.06) : .clear)
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(Color.secondary.opacity(isStopButtonHovered ? 0.55 : 0.35), lineWidth: 1)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isStopButtonHovered ? .primary : .secondary)
                .onHover { isStopButtonHovered = $0 }
                .help("Stop")
                .accessibilityLabel("Stop")
            }
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if controller.isSubmitting || controller.isResolvingQuestion {
            // A send or question response is still being accepted; spin in
            // place and keep further input out until its transaction settles.
            ProgressView()
                .controlSize(.small)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.secondary.opacity(0.16)))
                .help(controller.isResolvingQuestion ? "Submitting response…" : "Sending…")
        } else {
            // Goal mode still respects the connecting gate: `submitGoal…`
            // silently drops input while connecting, so an enabled-looking
            // button would be a lie.
            let hasSubmittableContent =
                controller.isGoalComposerArmed
                ? !controller.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                : hasComposerDraft || !visibleSlashMatches.isEmpty
            let isBlockedByCapabilities =
                hasSubmittableContent
                && controller.isConnectingToHarness
            let isEnabled =
                !isAppUpdateInProgress
                && (controller.isGoalComposerArmed
                    ? hasSubmittableContent
                        && !controller.isConnecting
                        && !controller.isConnectingToHarness
                    : !controller.isConnectingToHarness
                        && (controller.canSend || !visibleSlashMatches.isEmpty))
            ComposerSubmitButton(
                isEnabled: isEnabled,
                help: isAppUpdateInProgress
                    ? "Updating… you can send once the update finishes."
                    : isBlockedByCapabilities
                        ? "Connecting to harness…"
                        : controller.isConnecting
                            ? "Connecting… you can send once the agent is ready."
                            : "Send (↩)",
                accessibilityLabel: "Send"
            ) {
                submitOrAcceptSlash()
            }
        }
    }

    private var slashTokenRange: NSRange? {
        Self.slashTokenRange(in: controller.composerText, selection: selection)
    }

    private var slashQuery: String? {
        guard let range = slashTokenRange else { return nil }
        let text = controller.composerText as NSString
        return
            text
            .substring(with: NSRange(location: range.location + 1, length: range.length - 1))
            .lowercased()
    }

    /// The "/token" being typed at the caret — anywhere in the message, not
    /// just at its start: the nearest "/" before the caret with no whitespace
    /// in between, itself preceded by whitespace or the start of the text
    /// (so paths and URLs like "src/foo" never trigger the palette).
    static func slashTokenRange(in text: String, selection: NSRange) -> NSRange? {
        guard selection.length == 0 else { return nil }
        let text = text as NSString
        let caret = min(selection.location, text.length)
        var index = caret
        while index > 0 {
            let unit = text.character(at: index - 1)
            if isWhitespace(unit) { return nil }
            if unit == unichar(UInt8(ascii: "/")) {
                let slashIndex = index - 1
                guard slashIndex == 0 || isWhitespace(text.character(at: slashIndex - 1)) else {
                    return nil
                }
                return NSRange(location: slashIndex, length: caret - slashIndex)
            }
            index -= 1
        }
        return nil
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Local commands run in the app itself instead of being sent to the
    /// agent: /plan and /goal toggle their composer modes.
    private var localSlashCommands: [ComposerSlashItem] {
        var items: [ComposerSlashItem] = []
        if controller.hasPlanMode {
            items.append(
                ComposerSlashItem(name: "plan", description: "Toggle plan mode") {
                    Task { await controller.togglePlanMode() }
                }
            )
        }
        if controller.canEditGoal {
            items.append(
                ComposerSlashItem(name: "goal", description: "Toggle goal mode") {
                    withAnimation(.snappy(duration: 0.15)) { controller.toggleGoalComposer() }
                }
            )
        }
        return items
    }

    /// Keep the composer palette intentionally small. ACP agents can advertise
    /// large catalogs of global, builtin, and user skills as slash commands;
    /// those remain protocol metadata but are not surfaced here.
    private var slashCommands: [ComposerSlashItem] {
        localSlashCommands
    }

    private var slashMatches: [ComposerSlashItem] {
        guard let query = slashQuery else { return [] }
        let commands = slashCommands
        guard !commands.isEmpty else { return [] }
        if query.isEmpty {
            return commands
        }
        let exact = commands.filter { $0.name.lowercased() == query }
        let prefixed = commands.filter { command in
            command.name.lowercased().hasPrefix(query) && !exact.contains(where: { $0.id == command.id })
        }
        return exact + prefixed
    }

    /// The matches actually shown: empty while the menu is dismissed with Escape.
    private var visibleSlashMatches: [ComposerSlashItem] {
        isSlashMenuDismissed ? [] : slashMatches
    }

    private var isLoadingSlashCommands: Bool {
        slashQuery != nil && controller.isConnectingToHarness && !isSlashMenuDismissed
    }

    private var showsSlashCommandPopup: Bool {
        isLoadingSlashCommands || !visibleSlashMatches.isEmpty
    }

    private func submitOrAcceptSlash() {
        guard !controller.isResolvingQuestion else { return }
        if isLoadingSlashCommands { return }
        if let command = selectedSlashCommand {
            acceptSlashCommand(command)
        } else if controller.isGoalComposerArmed {
            Task { await controller.submitGoalFromComposer() }
        } else {
            Task { await controller.send() }
        }
    }

    private var selectedSlashCommand: ComposerSlashItem? {
        let matches = visibleSlashMatches
        guard !matches.isEmpty else { return nil }
        return matches[min(slashSelection, matches.count - 1)]
    }

    /// Accepts in place: the token at the caret is rewritten (harness
    /// commands) or excised (local commands), preserving the rest of the
    /// draft around it.
    private func acceptSlashCommand(_ command: ComposerSlashItem) {
        guard let tokenRange = slashTokenRange else { return }
        let text = controller.composerText as NSString
        if let action = command.action {
            controller.composerText = text.replacingCharacters(in: tokenRange, with: "")
            selection = NSRange(location: tokenRange.location, length: 0)
            action()
        } else {
            let insertion = "/\(command.name) "
            controller.composerText = text.replacingCharacters(in: tokenRange, with: insertion)
            selection = NSRange(
                location: tokenRange.location + (insertion as NSString).length,
                length: 0
            )
        }
        slashSelection = 0
    }

    private func handleKeyCommand(_ command: ComposerKeyCommand) -> Bool {
        // The palette handles keys first, so Escape always closes an open
        // palette before it can mean anything else (e.g. leaving goal mode).
        if handleSlashMenuKeyCommand(command) {
            return true
        }
        // Escape leaves goal mode (and restores the goal banner).
        if controller.isGoalComposerArmed, command == .dismissSelection {
            controller.exitGoalComposer()
            return true
        }
        return false
    }

    private func handleSlashMenuKeyCommand(_ command: ComposerKeyCommand) -> Bool {
        let matches = visibleSlashMatches
        guard !matches.isEmpty else { return false }
        switch command {
        case .moveSelectionUp:
            slashSelection = (slashSelection - 1 + matches.count) % matches.count
            return true
        case .moveSelectionDown:
            slashSelection = (slashSelection + 1) % matches.count
            return true
        case .acceptSelection:
            acceptSlashCommand(matches[min(slashSelection, matches.count - 1)])
            return true
        case .dismissSelection:
            isSlashMenuDismissed = true
            slashSelection = 0
            return true
        }
    }
}

#if DEBUG
    #Preview("Empty state composer") {
        ComposerCard(controller: .preview())
            .padding()
            .frame(width: 640)
    }

    #Preview("Connected composer") {
        ComposerCard(controller: .preview(model: .preview()), placeholder: "Ask for follow-up changes")
            .padding()
            .frame(width: 640)
    }
#endif
