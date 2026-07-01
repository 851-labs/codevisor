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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                ChatInputEditor(
                    text: $controller.composerText,
                    calculatedHeight: $editorHeight,
                    onSubmit: { Task { await controller.send() } },
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

            HStack(spacing: 10) {
                harnessMenu
                ForEach(controller.pickerOptions) { option in
                    configMenu(option)
                }
                if !controller.hasModeConfigPicker {
                    modeMenu
                }
                Spacer(minLength: 0)
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
    }

    @ViewBuilder
    private var sendButton: some View {
        if controller.isSending {
            Button { Task { await controller.stop() } } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Stop")
        } else {
            Button { Task { await controller.send() } } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(controller.canSend ? .white : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!controller.canSend)
            .help("Send (↩)")
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
