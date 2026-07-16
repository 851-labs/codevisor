import SwiftUI
import AppKit
import CodevisorCore
import ACPKit

extension EnvironmentValues {
    /// True while an app self-update or a selected-server update is installing.
    /// Injected at the root; the composer reads it to lock its submit action so
    /// no new turn starts while the app/server is about to restart.
    @Entry var isAppUpdateInProgress: Bool = false
}

/// The chat composer card: a multiline input (Return sends, Shift+Return adds a
/// newline) with an inline toolbar holding the combined model dropdown
/// (model/thinking level/speed), the harness picker (before connecting), any
/// remaining config pickers, and a send button.
struct ComposerCard: View {
    @Bindable var controller: SessionController
    var placeholder: String = "Do anything"
    /// The new-chat page hosts the harness picker in its own row below the
    /// composer; session pages keep it inline.
    var showsHarnessPicker: Bool = true
    /// Surfaces the composer's text view so keyboard handoffs can move
    /// first-responder focus to it.
    var onTextViewReady: ((SubmittingTextView) -> Void)? = nil

    @Environment(\.theme) private var theme
    /// Locks the submit action while an app/server update is installing so no
    /// new turn starts during the restart. Defaults to false (e.g. previews).
    @Environment(\.isAppUpdateInProgress) private var isAppUpdateInProgress
    @State private var editorHeight: CGFloat = 24
    @State private var slashSelection = 0
    @State private var isSlashMenuDismissed = false
    @State private var slashMenuContentHeight: CGFloat = 0
    @State private var isStopButtonHovered = false
    @State private var isSendButtonHovered = false
    @State private var isGoalBackButtonHovered = false

    /// Tallest the slash-command menu can grow before it scrolls (~6 rows).
    private static let slashMenuMaxHeight: CGFloat = 220

    var body: some View {
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
                        onSubmit: submitOrAcceptSlash,
                        onKeyCommand: handleKeyCommand,
                        onPasteAttachments: handlePastedAttachments,
                        onTextViewReady: onTextViewReady
                    )
                    .frame(height: editorHeight)
                    // Frozen while a send is being accepted (the moment before
                    // the session page opens; the send button spins instead)
                    // and while an update is installing (the app/server is
                    // about to restart).
                    .disabled(controller.isSubmitting || isAppUpdateInProgress)

                    if controller.composerText.isEmpty {
                        Text(controller.isGoalComposerArmed ? "Describe the goal" : placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    slashCommandPopup
                        .offset(y: -editorHeight - 10)
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
                    if showsHarnessPicker {
                        HarnessPickerMenu(controller: controller)
                    }
                    ForEach(controller.pickerOptions) { option in
                        configMenu(option)
                    }
                    // Tighter than the row's 10pt: the chips' hover fill bleeds
                    // 5pt into their gaps, so 5pt here keeps the visual rhythm
                    // even between these two bare circles.
                    HStack(spacing: 5) {
                        if controller.hasPlanMode {
                            planModeButton
                        }
                        if controller.canEditGoal {
                            goalModeButton
                        }
                    }
                    Spacer(minLength: 0)
                    // Action buttons cluster tighter than the picker chips.
                    // While the agent runs, stop takes the send slot; a draft
                    // in the composer brings send back with stop beside it.
                    HStack(spacing: 4) {
                        UsageRingButton(
                            usage: controller.usage,
                            limits: controller.usageLimits,
                            isLoadingLimits: controller.isLoadingUsageLimits,
                            limitsError: controller.usageLimitsError,
                            onRequestLimits: { await controller.loadUsageLimits() }
                        )
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
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.composerBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .onChange(of: slashQuery) { _, _ in
            // A new query invalidates both the keyboard selection and any
            // Escape-dismissal of the previous menu.
            slashSelection = 0
            isSlashMenuDismissed = false
        }
    }

    @ViewBuilder
    private var slashCommandPopup: some View {
        let matches = visibleSlashMatches
        if !matches.isEmpty {
            let selectedIndex = min(slashSelection, matches.count - 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                            slashCommandRow(command, isSelected: index == selectedIndex)
                                .id(command.id)
                        }
                    }
                    .padding(6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        slashMenuContentHeight = $0
                    }
                }
                .frame(height: min(slashMenuContentHeight, Self.slashMenuMaxHeight))
                .onChange(of: selectedIndex) { _, index in
                    guard matches.indices.contains(index) else { return }
                    proxy.scrollTo(matches[index].id)
                }
            }
            .frame(maxWidth: 520)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.composerBackground)
                    .shadow(radius: 12, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.separator, lineWidth: 1)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Slash commands")
            .accessibilityHint("Use the up and down arrows to choose a command, Return to accept, Escape to close")
        }
    }

    private func slashCommandRow(_ command: AvailableCommand, isSelected: Bool) -> some View {
        Button {
            acceptSlashCommand(command)
        } label: {
            HStack(spacing: 10) {
                Text("/\(command.name)")
                    .fontWeight(.medium)
                Text(command.description)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                Spacer(minLength: 0)
                if let hint = command.input?.hint {
                    Text(hint)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? theme.accent : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("/\(command.name), \(command.description)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func configMenu(_ option: SessionConfigOption) -> some View {
        Menu {
            ForEach(option.options) { value in
                Toggle(isOn: Binding(
                    get: { value.value == option.currentValue },
                    set: { isOn in
                        guard isOn else { return }
                        Task { await controller.setConfigOption(option.id, value.value) }
                    }
                )) {
                    Text(value.name)
                }
            }
        } label: {
            chipLabel(option.currentName)
        }
        .menuStyle(.button)
        .buttonStyle(HoverIconButtonStyle(shape: .chip))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(option.name)
    }

    /// Plan-mode toggle: on, the agent plans before making changes; off, it
    /// runs in the harness's full-access/build mode. Shown only when the
    /// harness maps a plan mode; the old multi-mode picker is gone (the other
    /// modes were never used).
    private var planModeButton: some View {
        let isOn = controller.isPlanModeOn
        return Button {
            Task { await controller.togglePlanMode() }
        } label: {
            Image(systemName: "checklist")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .foregroundStyle(isOn ? AnyShapeStyle(theme.windowBackground) : AnyShapeStyle(.secondary))
                .background(
                    Circle().fill(isOn ? Color.primary.opacity(0.82) : .clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(HoverIconButtonStyle())
        .disabled(controller.isPlanModeUpdatePending)
        .help("Toggle plan mode")
        .tooltip("Toggle plan mode")
        .accessibilityLabel("Plan mode")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
        .tooltip("Back — keep the current goal (esc)")
    }

    /// Goal-mode toggle: when armed, submitting the composer sets the text
    /// as the session goal instead of sending a prompt.
    private var goalModeButton: some View {
        let isArmed = controller.isGoalComposerArmed
        return Button {
            withAnimation(.snappy(duration: 0.15)) { controller.toggleGoalComposer() }
        } label: {
            Image(systemName: "target")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .foregroundStyle(isArmed ? AnyShapeStyle(theme.windowBackground) : AnyShapeStyle(.secondary))
                .background(
                    Circle().fill(isArmed ? Color.primary.opacity(0.82) : .clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(HoverIconButtonStyle())
        .help("Toggle goal mode")
        .tooltip("Toggle goal mode")
        .accessibilityLabel("Goal mode")
        .accessibilityAddTraits(isArmed ? .isSelected : [])
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
        .tooltip("Attach files")
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
                Button { Task { await controller.stop() } } label: {
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
                .tooltip("Stop")
            }
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if controller.isSubmitting {
            // The send was accepted and the session page is about to open;
            // spin in place and keep further input out.
            ProgressView()
                .controlSize(.small)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.secondary.opacity(0.16)))
                .help("Sending…")
        } else {
            let isEnabled = !isAppUpdateInProgress && (controller.isGoalComposerArmed
                ? !controller.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                : (controller.canSend || !visibleSlashMatches.isEmpty))
            Button { submitOrAcceptSlash() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(isEnabled ? theme.windowBackground : Color.secondary.opacity(0.75))
                    .background(
                        Circle()
                            .fill(isEnabled ? Color.primary.opacity(isSendButtonHovered ? 0.92 : 0.82) : Color.secondary.opacity(0.16))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .onHover { isSendButtonHovered = $0 }
            .help(isAppUpdateInProgress ? "Updating… you can send once the update finishes." : "Send (↩)")
            .tooltip(isAppUpdateInProgress ? "Updating… you can send once the update finishes." : "Send (↩)")
        }
    }

    private var slashQuery: String? {
        guard controller.composerText.hasPrefix("/") else { return nil }
        let firstLine = controller.composerText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let token = firstLine.dropFirst()
        guard !token.contains(" ") else { return nil }
        return String(token).lowercased()
    }

    private var slashMatches: [AvailableCommand] {
        guard let query = slashQuery else { return [] }
        let commands = controller.availableCommands
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
    private var visibleSlashMatches: [AvailableCommand] {
        isSlashMenuDismissed ? [] : slashMatches
    }

    private func submitOrAcceptSlash() {
        if let command = selectedSlashCommand {
            acceptSlashCommand(command)
        } else if controller.isGoalComposerArmed {
            Task { await controller.submitGoalFromComposer() }
        } else {
            Task { await controller.send() }
        }
    }

    private var selectedSlashCommand: AvailableCommand? {
        let matches = visibleSlashMatches
        guard !matches.isEmpty else { return nil }
        return matches[min(slashSelection, matches.count - 1)]
    }

    private func acceptSlashCommand(_ command: AvailableCommand) {
        controller.composerText = "/\(command.name) "
        slashSelection = 0
    }

    private func handleKeyCommand(_ command: ComposerKeyCommand) -> Bool {
        // Escape leaves goal mode (and restores the goal banner).
        if controller.isGoalComposerArmed, command == .dismissSelection {
            controller.exitGoalComposer()
            return true
        }
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

/// The staged-attachment strip above the composer input: image thumbnails and
/// file chips, each with a hover-revealed remove button and an
/// upload/failed badge.
struct ComposerAttachmentRow: View {
    @Bindable var controller: SessionController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(controller.composerAttachments) { attachment in
                    ComposerAttachmentThumb(
                        attachment: attachment,
                        onRemove: { controller.removeAttachment(id: attachment.id) },
                        onRetry: { controller.retryAttachment(id: attachment.id) }
                    )
                }
            }
        }
    }
}

private struct ComposerAttachmentThumb: View {
    @Environment(\.theme) private var theme
    @Environment(\.quickLook) private var quickLook
    let attachment: ComposerAttachment
    let onRemove: () -> Void
    let onRetry: () -> Void

    @State private var isHovered = false
    /// Decoded once per attachment: `NSImage(data:)` in `body` re-decoded the
    /// image on every re-render (every keystroke while the composer holds
    /// attachments).
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.hasVisualPreview, let image = thumbnail {
                    // A tap gesture rather than a Button: buttons add their own
                    // hover/press highlight over the artwork.
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.separator, lineWidth: 1)
                        )
                        .overlay(alignment: .bottomLeading) {
                            if attachment.isPDF {
                                PDFBadge()
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { preview() }
                        .help(attachment.name)
                } else {
                    AttachmentFileChip(name: attachment.name) { preview() }
                }
            }
            .overlay {
                stateBadge
            }

            // Always mounted and toggled instantly (no animation): any
            // animated change here rebuilds AppKit hover tracking mid-hover,
            // which oscillates the hover state and flickers.
            removeButton
                .padding(4)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
        }
        .onHover { hovering in
            guard hovering != isHovered else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { isHovered = hovering }
        }
        .task(id: attachment.id) {
            guard attachment.hasVisualPreview, thumbnail == nil else { return }
            let data = attachment.localData
            // Decode off the main thread — a pasted screenshot can be many
            // megabytes and the thumb is 56 pt.
            thumbnail = await Task.detached(priority: .userInitiated) {
                NSImage(data: data)
            }.value
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Attachment \(attachment.name)")
    }

    private func preview() {
        quickLook?.present(
            .local(
                data: attachment.localData,
                name: attachment.name,
                mimeType: attachment.mimeType
            ),
            attachmentStore: nil
        )
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch attachment.state {
        case .uploading:
            RoundedRectangle(cornerRadius: 8)
                .fill(.black.opacity(0.25))
                .overlay(ProgressView().controlSize(.small))
                .allowsHitTesting(false)
        case let .failed(reason):
            Button {
                onRetry()
            } label: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black.opacity(0.35))
                    .overlay(
                        VStack(spacing: 2) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(theme.statusWarn)
                            Text("Retry")
                                .font(.caption2)
                                .foregroundStyle(.white)
                        }
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Upload failed: \(reason). Click to retry.")
        case .uploaded:
            EmptyView()
        }
    }

    private var removeButton: some View {
        Button {
            onRemove()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                // Fixed dark-on-light styling (not theme-derived): the button
                // sits on arbitrary image content, so it needs contrast
                // against white screenshots and dark thumbnails alike.
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(.black.opacity(0.78)))
                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Remove attachment")
        .accessibilityLabel("Remove \(attachment.name)")
    }
}

/// The label for composer accessory dropdowns: icon, text, and a chevron with
/// one shared styling so the pickers in the row read identically.
struct PickerChip<Icon: View>: View {
    let text: String
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: 5) {
            icon
            Text(text)
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
    }
}

/// The combined model dropdown: one chip that opens nested menus for the
/// model, thinking level, and speed. Collapsed it reads
/// "[⚡ when fast] Model ThinkingLevel" — the model in the normal text color,
/// the thinking level subdued.
struct ModelConfigMenu: View {
    @Bindable var controller: SessionController

    var body: some View {
        if controller.hasModelMenu {
            Menu {
                if let option = controller.modelOption {
                    section("Model", option)
                }
                if let option = controller.thoughtLevelOption {
                    section("Reasoning", option)
                }
                if let option = controller.speedOption {
                    section("Speed", option)
                }
            } label: {
                chipLabel
            }
            .menuStyle(.button)
            .buttonStyle(HoverIconButtonStyle(shape: .chip))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Model, thinking level, and speed")
            .accessibilityLabel("Model settings")
        }
    }

    // Toggles rather than checkmark labels: macOS menus drop SF Symbol images,
    // so only a Toggle reliably renders the native selected checkmark.
    // Flat titled sections rather than nested submenus: everything is one
    // click away and the current value of each group is scannable at once.
    private func section(_ title: String, _ option: SessionConfigOption) -> some View {
        Section(title) {
            ForEach(option.options) { value in
                Toggle(isOn: Binding(
                    get: { value.value == option.currentValue },
                    set: { isOn in
                        guard isOn else { return }
                        Task { await controller.setConfigOption(option.id, value.value) }
                    }
                )) {
                    Text(value.name)
                }
                .help(value.description ?? "")
            }
        }
    }

    private var isFastSpeed: Bool {
        controller.speedOption?.currentValue == "fast"
    }

    private var chipLabel: some View {
        HStack(spacing: 5) {
            if isFastSpeed {
                Image(systemName: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Fast speed")
            }
            if let model = controller.modelOption {
                Text(model.currentName)
                    .foregroundStyle(.primary)
            }
            if let thought = controller.thoughtLevelOption {
                Text(thought.currentName)
                    .foregroundStyle(.secondary)
            }
        }
        // Cover the whole chip (including gaps) so a click anywhere opens it.
        .contentShape(Rectangle())
    }
}

/// The harness picker chip. Only shown while the harness can still be chosen
/// (an unsent draft); on a session page — including the moment a first send is
/// still connecting — it renders nothing.
struct HarnessPickerMenu: View {
    @Bindable var controller: SessionController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if controller.canChooseHarness {
            if controller.preparationState == .loading {
                // HIG: use a small, unlabeled indeterminate spinner for an
                // unpredictable background operation in a constrained control.
                ProgressView()
                    .controlSize(.small)
                    .frame(minWidth: 96)
                    .help("Checking available agents")
                    .accessibilityLabel("Checking available agents")
            } else if controller.preparationState == .failed {
                Button {
                    Task { await controller.prepare() }
                } label: {
                    PickerChip(text: "Agents unavailable") {
                        Image(systemName: "exclamationmark.triangle")
                    }
                }
                .buttonStyle(HoverIconButtonStyle(shape: .chip))
                .help("Couldn't load agents. Click to try again.")
                .accessibilityLabel("Agents unavailable. Try again")
            } else {
                Menu {
                    ForEach(controller.harnesses) { harness in
                        Toggle(isOn: Binding(
                            get: { harness.id == controller.selectedHarnessId },
                            set: { isOn in
                                guard isOn else { return }
                                Task { await controller.selectHarness(harness.id) }
                            }
                        )) {
                            Label {
                                Text(harness.name)
                            } icon: {
                                HarnessIcon(
                                    harnessId: harness.id,
                                    fallbackSymbolName: harness.symbolName
                                )
                            }
                        }
                    }

                    if !controller.harnesses.isEmpty {
                        Divider()
                    }

                    Button("Manage Harnesses…") {
                        SettingsRouter.shared.selectedTab = .harnesses
                        openSettings()
                    }
                } label: {
                    PickerChip(
                        text: controller.harnesses.isEmpty
                            ? "No agent installed"
                            : controller.selectedHarness?.name ?? "Choose agent"
                    ) {
                        if let harness = controller.selectedHarness {
                            HarnessIcon(harnessId: harness.id, fallbackSymbolName: harness.symbolName)
                        }
                    }
                }
                .menuStyle(.button)
                .buttonStyle(HoverIconButtonStyle(shape: .chip))
                .menuIndicator(.hidden)
                .fixedSize()
            }
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
