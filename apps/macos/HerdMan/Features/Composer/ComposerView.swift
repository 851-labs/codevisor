import SwiftUI
import AppKit
import HerdManCore
import ACPKit

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
    /// Surfaces the composer's text view so the terminal focus handoff can move
    /// first-responder focus to it.
    var onTextViewReady: ((NSView) -> Void)? = nil

    @Environment(\.theme) private var theme
    @State private var editorHeight: CGFloat = 24
    @State private var slashSelection = 0
    @State private var isSlashMenuDismissed = false
    @State private var slashMenuContentHeight: CGFloat = 0
    @State private var isStopButtonHovered = false
    @State private var isSendButtonHovered = false

    /// Tallest the slash-command menu can grow before it scrolls (~6 rows).
    private static let slashMenuMaxHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The attachment strip sits tight against the input, closer than
            // the card's usual element spacing.
            VStack(alignment: .leading, spacing: 4) {
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
                    // the session page opens); the send button spins instead.
                    .disabled(controller.isSubmitting)

                    if controller.composerText.isEmpty {
                        Text(placeholder)
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
                attachButton
                ModelConfigMenu(controller: controller)
                if showsHarnessPicker {
                    HarnessPickerMenu(controller: controller)
                }
                ForEach(controller.pickerOptions) { option in
                    configMenu(option)
                }
                if !controller.hasModeConfigPicker {
                    modeMenu
                }
                Spacer(minLength: 0)
                UsageRingButton(usage: controller.usage)
                stopButton
                sendButton
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
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(option.name)
    }

    @ViewBuilder
    private var modeMenu: some View {
        if let modes = controller.modeState, modes.availableModes.count > 1 {
            Menu {
                ForEach(modes.availableModes) { mode in
                    Toggle(isOn: Binding(
                        get: { mode.id == modes.currentModeId },
                        set: { isOn in
                            guard isOn else { return }
                            Task { await controller.setMode(mode.id) }
                        }
                    )) {
                        Text(mode.name)
                    }
                }
            } label: {
                chipLabel(modes.availableModes.first { $0.id == modes.currentModeId }?.name ?? "Mode")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func chipLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .foregroundStyle(.secondary)
        // Cover the whole chip (including the gap before the chevron) so a
        // click anywhere on it opens the menu.
        .contentShape(Rectangle())
    }

    private var attachButton: some View {
        Button {
            presentOpenPanel()
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            Button { Task { await controller.stop() } } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 28, height: 28)
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
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if controller.isSubmitting {
            // The send was accepted and the session page is about to open;
            // spin in place and keep further input out.
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.secondary.opacity(0.16)))
                .help("Sending…")
        } else {
            let isEnabled = controller.canSend || !visibleSlashMatches.isEmpty
            Button { submitOrAcceptSlash() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
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
            .help("Send (↩)")
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
    @Environment(\.lightbox) private var lightbox
    let attachment: ComposerAttachment
    let onRemove: () -> Void
    let onRetry: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.hasVisualPreview, let image = NSImage(data: attachment.localData) {
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
                        .onTapGesture {
                            lightbox?.present(
                                .local(data: attachment.localData, name: attachment.name),
                                imageStore: nil
                            )
                        }
                        .help(attachment.name)
                } else {
                    AttachmentFileChip(name: attachment.name)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Attachment \(attachment.name)")
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
            Image(systemName: "chevron.down").font(.caption2)
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
                    submenu("Model", option)
                }
                if let option = controller.thoughtLevelOption {
                    submenu("Reasoning", option)
                }
                if let option = controller.speedOption {
                    submenu("Speed", option)
                }
            } label: {
                chipLabel
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Model, thinking level, and speed")
            .accessibilityLabel("Model settings")
        }
    }

    // Toggles rather than checkmark labels: macOS menus drop SF Symbol images,
    // so only a Toggle reliably renders the native selected checkmark.
    private func submenu(_ title: String, _ option: SessionConfigOption) -> some View {
        Menu(title) {
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
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        // Cover the whole chip (including gaps) so a click anywhere opens it.
        .contentShape(Rectangle())
    }
}

/// The harness picker chip. Only shown before the first message (drafts); on a
/// session page the harness can't change, so it renders nothing.
struct HarnessPickerMenu: View {
    @Bindable var controller: SessionController

    var body: some View {
        if controller.conversation.isEmpty {
            if controller.harnesses.isEmpty {
                PickerChip(text: "No agent installed") { EmptyView() }
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
                } label: {
                    PickerChip(text: controller.selectedHarness?.name ?? "Choose agent") {
                        if let harness = controller.selectedHarness {
                            HarnessIcon(harnessId: harness.id, fallbackSymbolName: harness.symbolName)
                        }
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
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
