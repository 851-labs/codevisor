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

    private static let minEditorHeight: CGFloat = 30
    private static let collapsedMaxEditorHeight: CGFloat = 148
    /// Chrome around the editor inside the card: paddings, toolbar row, and
    /// the spacing between them.
    private static let cardChromeHeight: CGFloat = 96

    /// `measuredTextHeight` is the text view's own content height (insets
    /// included), reported by the UIKit editor — no mirror, no guessing.
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
        VStack(alignment: .leading, spacing: 8) {
            // Where a brand-new chat runs (project root / worktree) floats
            // above the card, like the macOS new-chat configuration row —
            // but only when there's actually a choice: a non-git project
            // with no worktree has exactly one place to run.
            if controller.canChooseHarness, hasMultipleRunLocations {
                runLocationChip
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .composerGlassSurface(cornerRadius: 18)
            }
            card
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
                // A UIKit text view: return inserts newlines, the content
                // height comes straight from the text view (no mirror), and
                // the last line renders — SwiftUI's TextEditor drops it when
                // scrolling is disabled inside a fixed frame.
                ComposerTextView(
                    text: $text,
                    isEditable: !(controller.isSubmitting || controller.isResolvingQuestion),
                    // Scrolling stays off unless the text really overflows,
                    // so a drag on the card is never swallowed by the editor.
                    isScrollEnabled: editorHeight < measuredTextHeight,
                    contentHeight: $measuredTextHeight
                )
                .frame(height: editorHeight)

                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
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
        // The transcript fades where it slides underneath the card: this
        // backdrop sits behind the glass, its gradient starting exactly at
        // the card's top edge and fully opaque well before the card's
        // bottom. It tracks a resize drag frame-for-frame and only extends
        // downward, covering the gap to the screen edge.
        .background {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        Color(.systemGroupedBackground).opacity(0),
                        Color(.systemGroupedBackground)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 28)
                Rectangle()
                    .fill(Color(.systemGroupedBackground))
            }
            .padding(.bottom, -60)
            .allowsHitTesting(false)
        }
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

    /// Whether there's more than one place this chat could run. Git projects
    /// offer New Worktree; a session already bound to a worktree offers it
    /// back. Otherwise the project root is the only option and the picker
    /// hides.
    private var hasMultipleRunLocations: Bool {
        if controller.project.isGitRepository { return true }
        if case .existingWorktree = controller.runContext { return true }
        return false
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
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
            )
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

/// The model / thinking-level chip — "Sonnet High" — opening the searchable
/// model sheet (model → thinking → speed, grouped by harness for new chats).
private struct ModelConfigChip: View {
    @Bindable var controller: SessionController
    @State private var showsPicker = false

    private var isFastSpeed: Bool { controller.speedOption?.currentValue == "fast" }

    var body: some View {
        if controller.isLoadingModelMenu {
            ProgressView()
                .controlSize(.small)
        } else if controller.hasModelMenu {
            Button {
                showsPicker = true
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
            .sheet(isPresented: $showsPicker) {
                ModelPickerSheet(controller: controller)
            }
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


/// The composer's text engine: UITextView under SwiftUI. Newlines on return,
/// exact content-height reporting (insets included), scroll only on overflow.
private struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var isScrollEnabled: Bool
    @Binding var contentHeight: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text {
            view.text = text
        }
        view.isEditable = isEditable
        if view.isScrollEnabled != isScrollEnabled {
            view.isScrollEnabled = isScrollEnabled
        }
        context.coordinator.reportHeight(of: view, to: $contentHeight)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>
        private var lastReported: CGFloat = 0

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }

        func reportHeight(of view: UITextView, to binding: Binding<CGFloat>) {
            let width = view.bounds.width
            guard width > 0 else { return }
            let height = view.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
            guard abs(height - lastReported) > 0.5 else { return }
            lastReported = height
            // Defer: updateUIView runs inside a view update.
            Task { @MainActor in
                binding.wrappedValue = height
            }
        }
    }
}
