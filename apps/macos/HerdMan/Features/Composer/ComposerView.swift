import SwiftUI
import AppKit
import HerdManCore
import ACPKit
import ACPAgents

/// The chat composer card: a multiline input (Return sends, Shift+Return adds a
/// newline) with an inline toolbar holding the harness picker (before
/// connecting) or the model/reasoning pickers (once connected) and a send button.
struct ComposerCard: View {
    @Bindable var controller: SessionController
    var placeholder: String = "Do anything"
    /// Surfaces the composer's text view so the terminal focus handoff can move
    /// first-responder focus to it.
    var onTextViewReady: ((NSView) -> Void)? = nil

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
            ZStack(alignment: .topLeading) {
                ChatInputEditor(
                    text: $controller.composerText,
                    calculatedHeight: $editorHeight,
                    onSubmit: submitOrAcceptSlash,
                    onKeyCommand: handleKeyCommand,
                    onTextViewReady: onTextViewReady
                )
                .frame(height: editorHeight)

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

            HStack(spacing: 10) {
                harnessMenu
                ForEach(controller.pickerOptions) { option in
                    configMenu(option)
                }
                if !controller.hasModeConfigPicker {
                    modeMenu
                }
                Spacer(minLength: 0)
                stopButton
                sendButton
            }
            .font(.callout)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
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
                    .fill(Color(nsColor: .controlBackgroundColor))
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
                    .fill(isSelected ? Color.accentColor : .clear)
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
                Button {
                    Task { await controller.setConfigOption(option.id, value.value) }
                } label: {
                    if value.value == option.currentValue {
                        Label(value.name, systemImage: "checkmark")
                    } else {
                        Text(value.name)
                    }
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
                    Button {
                        Task { await controller.setMode(mode.id) }
                    } label: {
                        if mode.id == modes.currentModeId {
                            Label(mode.name, systemImage: "checkmark")
                        } else {
                            Text(mode.name)
                        }
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

    /// The harness picker is only shown before the first message (the new-chat
    /// page); on a session page the harness can't change, so it's hidden.
    @ViewBuilder
    private var harnessMenu: some View {
        if controller.conversation.isEmpty {
            if controller.harnesses.isEmpty {
                chipLabel("No agent installed")
            } else {
                Menu {
                    ForEach(controller.harnesses) { harness in
                        Button {
                            Task { await controller.selectHarness(harness.id) }
                        } label: {
                            if harness.id == controller.selectedHarnessId {
                                Label(harness.name, systemImage: "checkmark")
                            } else {
                                Text(harness.name)
                            }
                        }
                    }
                } label: {
                    chipLabel(controller.selectedHarness?.name ?? "Choose agent")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
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
        let isEnabled = controller.canSend || !visibleSlashMatches.isEmpty
        Button { submitOrAcceptSlash() } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 28, height: 28)
                .foregroundStyle(isEnabled ? Color(nsColor: .windowBackgroundColor) : Color.secondary.opacity(0.75))
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
