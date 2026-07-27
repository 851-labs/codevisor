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
    /// The tallest the whole card may grow to when dragged open.
    let maxHeight: CGFloat
    /// Reported back so the transcript can inset its content and place the
    /// fade. Only the collapsed height is published — publishing live drag
    /// heights would re-measure the transcript on every gesture frame.
    @Binding var collapsedHeight: CGFloat

    @FocusState private var isFocused: Bool
    @State private var text = ""
    /// Measured height of the text itself, used for the collapsed size and as
    /// the starting point of a drag.
    @State private var measuredTextHeight: CGFloat = 0
    @State private var isExpanded = false
    /// Live drag offset. GestureState resets itself when the gesture ends or is
    /// cancelled, so the height can't be left stale by a race, and dragging
    /// doesn't write view state on every frame.
    @GestureState private var dragTranslation: CGFloat = 0
    /// The height at the moment the finger lifted, pinned for the settle
    /// animation so release doesn't flash back to the old resting height.
    @State private var releaseHeight: CGFloat?
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

    private static let minEditorHeight: CGFloat = 22
    private static let collapsedMaxEditorHeight: CGFloat = 132
    /// Chrome around the editor inside the card: paddings, toolbar row, and
    /// the spacing between them.
    private static let cardChromeHeight: CGFloat = 96

    private var collapsedEditorHeight: CGFloat {
        min(max(measuredTextHeight, Self.minEditorHeight), Self.collapsedMaxEditorHeight)
    }

    private var maxEditorHeight: CGFloat {
        max(Self.collapsedMaxEditorHeight, maxHeight - Self.cardChromeHeight)
    }

    /// Where the card rests when no drag is in flight.
    private var baseEditorHeight: CGFloat {
        isExpanded ? maxEditorHeight : collapsedEditorHeight
    }

    private var editorHeight: CGFloat {
        if dragTranslation != 0 {
            return min(maxEditorHeight, max(collapsedEditorHeight, baseEditorHeight - dragTranslation))
        }
        return releaseHeight ?? baseEditorHeight
    }

    private var placeholder: String {
        controller.isSending ? "Reply while it works" : "Ask for follow-up changes"
    }

    var body: some View {
        VStack(spacing: 8) {
            card
            // A brand-new chat mirrors the macOS new-chat page: harness and
            // run-location pickers in their own capsule row under the card.
            if controller.canChooseHarness {
                HStack(spacing: 10) {
                    harnessChip
                    Divider().frame(height: 14)
                    runLocationChip
                }
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .composerGlassSurface(cornerRadius: 22)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            // Publish only the resting size; see `collapsedHeight`.
            if !isExpanded, dragTranslation == 0, releaseHeight == nil {
                collapsedHeight = height
            }
        }
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

    private var card: some View {
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
                // Mirrors the editor's text to measure its natural height, so
                // the collapsed size tracks content and a drag starts from
                // exactly where the card already is.
                Text(text.isEmpty ? " " : text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        measuredTextHeight = height
                    }
                    .opacity(0)
                    .accessibilityHidden(true)

                ScrollView {
                    TextField("", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                        .disabled(controller.isSubmitting || controller.isResolvingQuestion)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                // Scrolling stays off unless the text really overflows, so a
                // drag on the card is never swallowed by the editor.
                .scrollDisabled(editorHeight >= measuredTextHeight)
                .frame(height: editorHeight)

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
        .contentShape(Rectangle())
        // A single owner for the whole card: dragging works anywhere on it,
        // and no two recognizers can fight over one touch.
        .simultaneousGesture(expansionDrag)
        .accessibilityAction(named: isExpanded ? "Collapse composer" : "Expand composer") {
            setExpanded(!isExpanded)
        }
        // Resizing the card shouldn't ripple layout out into the transcript
        // behind it.
        .geometryGroup()
    }

    /// Drag the card open and closed from anywhere on it: the top edge
    /// follows the finger, and releasing snaps to fully expanded or collapsed
    /// based on where the gesture was heading.
    private var expansionDrag: some Gesture {
        // Global coordinates, not the default local space: the gesture is
        // attached to the view it resizes, so measuring in the card's own
        // space fed its growth back into the reported translation and the
        // card chased its own tail.
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($dragTranslation) { value, translation, transaction in
                // Direct manipulation: the card matches the touch exactly.
                // Any inherited animation would make it chase the finger and
                // settle, which reads as jitter.
                transaction.disablesAnimations = true
                translation = value.translation.height
            }
            .onEnded { value in
                let base = baseEditorHeight
                let height = min(
                    maxEditorHeight,
                    max(collapsedEditorHeight, base - value.translation.height)
                )
                // A flick commits on velocity alone; otherwise a short pull
                // away from the resting state is enough.
                let velocity = value.velocity.height
                let travelled = height - base
                let commitDistance: CGFloat = 56
                let shouldExpand: Bool
                if velocity < -220 {
                    shouldExpand = true
                } else if velocity > 220 {
                    shouldExpand = false
                } else if isExpanded {
                    shouldExpand = travelled > -commitDistance
                } else {
                    shouldExpand = travelled > commitDistance
                }
                // GestureState zeroes itself the instant the gesture ends,
                // which would snap the card back to its old resting height for
                // a frame before the settle animation started. Pin the release
                // height un-animated first, then animate that override away
                // toward the new resting state, so the settle starts exactly
                // where the finger let go.
                var pin = Transaction()
                pin.disablesAnimations = true
                withTransaction(pin) { releaseHeight = height }
                isExpanded = shouldExpand
                withAnimation(.snappy(duration: 0.28)) { releaseHeight = nil }
            }
    }

    private func setExpanded(_ expand: Bool) {
        withAnimation(.snappy(duration: 0.28)) {
            isExpanded = expand
        }
    }

    // MARK: - New-chat pickers

    /// Harness choice for a chat whose agent hasn't spawned yet — the iOS
    /// twin of the macOS HarnessPickerMenu.
    private var harnessChip: some View {
        Menu {
            ForEach(controller.harnesses, id: \.id) { harness in
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
            chipLabel(
                controller.selectedHarness?.name ?? "Agent",
                systemImage: "cpu"
            )
        }
        .accessibilityLabel("Agent")
    }

    /// Where the chat's commands run: the project root or a fresh worktree —
    /// the macOS run-location picker, reduced to the contexts this client
    /// knows about.
    private var runLocationChip: some View {
        Menu {
            Button {
                selectRunContext(.projectRoot)
            } label: {
                menuRow(
                    controller.project.name,
                    systemImage: "folder.fill",
                    isSelected: controller.runContext == .projectRoot
                )
            }
            if case let .existingWorktree(name, path) = controller.runContext {
                Button {
                    selectRunContext(.existingWorktree(name: name, path: path))
                } label: {
                    menuRow(name, systemImage: "arrow.triangle.branch", isSelected: true)
                }
            }
            if controller.project.isGitRepository {
                Divider()
                Button {
                    selectRunContext(.newWorktree)
                } label: {
                    menuRow(
                        "New worktree",
                        systemImage: "arrow.triangle.branch",
                        isSelected: controller.runContext == .newWorktree
                    )
                }
            }
        } label: {
            chipLabel(runContextTitle, systemImage: runContextSymbol)
        }
        .accessibilityLabel("Run location")
    }

    private var runContextTitle: String {
        switch controller.runContext {
        case .projectRoot: controller.project.name
        case let .existingWorktree(name, _): name
        case .newWorktree: "New worktree"
        }
    }

    private var runContextSymbol: String {
        controller.runContext == .projectRoot ? "folder.fill" : "arrow.triangle.branch"
    }

    private func selectRunContext(_ context: SessionController.RunContextSelection) {
        controller.selectRunContext(context)
        Task { await controller.reconnect() }
    }

    private func chipLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption)
            Text(title)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func menuRow(_ title: String, systemImage: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Label(title, systemImage: systemImage)
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
            setExpanded(false)
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

