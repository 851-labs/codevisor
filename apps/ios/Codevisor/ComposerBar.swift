import ACPKit
import CodevisorCore
import CodevisorUI
import PhotosUI
import SwiftUI

/// The iOS composer, matching the macOS composer's structure: the input on its
/// own line with the toolbar row beneath it (attach, model/thinking chip,
/// config chips, then stop/send), all inside one Liquid Glass card.
///
/// The editor keeps its text in local state and only writes it to the
/// controller on send (and when leaving, so drafts persist). Binding straight
/// to `controller.composerText` published an observable mutation per keystroke,
/// which — with the composer inside the transcript's safe-area inset — forced
/// the whole bottom-anchored scroll view to re-measure every character.
struct ComposerBar: View {
    @Bindable var controller: SessionController
    @FocusState private var isFocused: Bool
    @State private var text = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isPickingPhotos = false
    @State private var isPickingFiles = false
    @State private var isCapturingPhoto = false

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        (!trimmed.isEmpty || !controller.composerAttachments.isEmpty)
            && !controller.isSubmitting
            && !controller.isConnecting
            && controller.configurationValidationState == .ready
    }

    private var placeholder: String {
        controller.isSending ? "Reply while it works" : "Ask for follow-up changes"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !controller.composerAttachments.isEmpty {
                ComposerAttachmentStrip(controller: controller)
            }
            if let message = controller.configurationValidationError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let message = controller.configurationAdjustmentMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ZStack(alignment: .topLeading) {
                TextField("", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($isFocused)
                    .disabled(controller.isSubmitting || controller.isResolvingQuestion)
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 10) {
                attachButton
                ModelConfigChip(controller: controller)
                ForEach(controller.pickerOptions) { option in
                    ConfigChip(controller: controller, option: option)
                }
                Spacer(minLength: 0)
                // Mirrors the macOS toolbar: while the agent runs, stop takes
                // the send slot; typing a draft brings send back beside it.
                HStack(spacing: 6) {
                    if controller.isSending {
                        stopButton
                        if !trimmed.isEmpty { sendButton }
                    } else {
                        sendButton
                    }
                }
            }
            .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .composerGlassSurface(cornerRadius: ComposerGlassStyle.composerCornerRadius)
        .onAppear { text = controller.composerText }
        .onDisappear { controller.composerText = text }
        .photosPicker(
            isPresented: $isPickingPhotos,
            selection: $photoItems,
            maxSelectionCount: remainingAttachmentSlots,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            let picked = items
            photoItems = []
            Task { await ComposerAttachmentStaging.stage(photoItems: picked, into: controller) }
        }
        .fileImporter(
            isPresented: $isPickingFiles,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            ComposerAttachmentStaging.stage(pickedURLs: urls, into: controller)
        }
        .fullScreenCover(isPresented: $isCapturingPhoto) {
            CameraPicker { image in
                ComposerAttachmentStaging.stage(cameraImage: image, into: controller)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Controls

    private var remainingAttachmentSlots: Int {
        max(0, SessionController.maxAttachments - controller.composerAttachments.count)
    }

    private var attachButton: some View {
        Menu {
            Button {
                isPickingPhotos = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    isCapturingPhoto = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
            }
            Button {
                isPickingFiles = true
            } label: {
                Label("Choose Files", systemImage: "folder")
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(remainingAttachmentSlots == 0)
        .accessibilityLabel("Attach files")
    }

    private var sendButton: some View {
        Button {
            let outgoing = text
            text = ""
            controller.composerText = outgoing
            isFocused = false
            Task { await controller.send() }
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .frame(width: 30, height: 30)
                .foregroundStyle(canSend ? Color(.systemBackground) : Color.secondary.opacity(0.75))
                .background(
                    Circle().fill(
                        canSend ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.16)
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel("Send")
    }

    private var stopButton: some View {
        Button {
            Task { await controller.stop() }
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30)
                .foregroundStyle(.secondary)
                .background(Circle().fill(Color.secondary.opacity(0.16)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop")
    }
}

/// The model / thinking-level chip — "Sonnet High" — opening the same model,
/// thinking, and speed sections the macOS menu shows.
private struct ModelConfigChip: View {
    @Bindable var controller: SessionController

    private var isFastSpeed: Bool { controller.speedOption?.currentValue == "fast" }

    var body: some View {
        if controller.isLoadingModelMenu {
            ProgressView()
                .controlSize(.small)
        } else if controller.hasModelMenu {
            Menu {
                if let option = controller.modelOption {
                    section("Model", option)
                }
                ForEach(controller.thoughtLevelOptions) { option in
                    section(option.name, option)
                }
                if let option = controller.speedOption {
                    section("Speed", option)
                }
            } label: {
                HStack(spacing: 5) {
                    if isFastSpeed {
                        Image(systemName: "bolt.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let model = controller.modelOption {
                        Text(model.currentName)
                            .foregroundStyle(.primary)
                    }
                    ForEach(controller.thoughtLevelOptions) { thought in
                        Text(thought.currentName)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Model settings")
        }
    }

    private func section(_ title: String, _ option: SessionConfigOption) -> some View {
        Section(title) {
            Picker(title, selection: Binding(
                get: { controller.configOptions.first { $0.id == option.id }?.currentValue ?? option.currentValue },
                set: { value in Task { await controller.setConfigOption(option.id, value) } }
            )) {
                ForEach(option.options) { value in
                    Text(value.name).tag(value.value)
                }
            }
            .pickerStyle(.inline)
        }
    }
}

/// A remaining harness config option (anything that isn't model/thinking/speed)
/// as its own chip, mirroring the macOS toolbar.
private struct ConfigChip: View {
    @Bindable var controller: SessionController
    let option: SessionConfigOption

    var body: some View {
        Menu {
            Picker(option.name, selection: Binding(
                get: { controller.configOptions.first { $0.id == option.id }?.currentValue ?? option.currentValue },
                set: { value in Task { await controller.setConfigOption(option.id, value) } }
            )) {
                ForEach(option.options) { value in
                    Text(value.name).tag(value.value)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(option.currentName)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.name)
    }
}
