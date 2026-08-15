import ACPKit
import CodevisorCore
import CodevisorUI
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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
    /// Owned by the host screen so it can hide the composer's accessories
    /// (scroll-to-bottom, notice rails, …) while the card is dragged open.
    @Binding var isExpanded: Bool
    /// The new-chat page shows the project/run-location chips above the
    /// card; established chats never do (their directory is fixed).
    var showsRunPickers: Bool = false
    /// A stable, one-shot request for New Chat's initial focus. The token is
    /// intentionally not a Bool: after the user dismisses the keyboard,
    /// ordinary SwiftUI updates must not make the editor first responder
    /// again.
    var initialFocusRequest: UUID? = nil
    var onInitialFocusRequestFulfilled: ((UUID) -> Void)? = nil
    /// First-send promotion transfers focus directly to the already-mounted
    /// destination editor. Keeping this editor first responder until that
    /// handoff prevents a keyboard dismissal/reappearance cycle.
    var preservesFocusAfterSend = false
    /// First-send promotion keeps one concrete UIKit editor alive while its
    /// container moves from the native sheet into the real workspace route.
    /// Focus state alone is not enough: dismissing a modal destroys the old
    /// responder before SwiftUI can focus a newly-created replacement.
    var textEditorHandoffRole: ComposerTextEditorHandoffRole = .none
    /// Identity of this one sheet presentation. The retained draft controller
    /// deliberately survives dismiss/reopen, so it must never identify a
    /// concrete UIKit editor. Only the short-lived NewChatFlow may do that.
    var textEditorHandoffID: UUID? = nil
    /// Window-space editor bounds are the animation's real source geometry.
    var onSendSourceFrameChange: ((CGRect) -> Void)? = nil
    /// Captured before the controller clears its durable draft. New Chat uses
    /// this to give the outgoing text one visual owner during sheet promotion.
    var onWillSend: ((String) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var text = ""
    /// The source New Chat editor keeps drawing the submitted glyphs until
    /// the promotion layer has covered it. The durable controller draft is
    /// already empty, so newly mounted destination composers remain empty.
    @State private var retainsSubmittedTextForPromotion = false
    /// Measured height of the text itself, used for the collapsed size and as
    /// the starting point of a drag.
    @State private var measuredTextHeight: CGFloat = 0
    /// Measured height of the run-picker chip row (new-chat page only), so
    /// an expanded card stops below it instead of shoving it under the bar.
    @State private var runPickersHeight: CGFloat = 0
    /// Live drag offset. GestureState resets itself when the gesture ends or is
    /// cancelled, so the height can't be left stale by a race, and dragging
    /// doesn't write view state on every frame.
    @GestureState private var dragTranslation: CGFloat = 0
    /// Live offset of the editor's own UIKit resize pan (see
    /// `HeightReportingTextView.expansionPan`) — the grab-anywhere gesture
    /// over the text area, arbitrated against text selection by UIKit.
    @State private var panTranslation: CGFloat = 0
    /// The height at the moment the finger lifted, pinned for the settle
    /// animation so release doesn't flash back to the old resting height.
    @State private var releaseHeight: CGFloat?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isPickingPhotos = false
    @State private var isPickingFiles = false
    @State private var isCapturingPhoto = false
    @State private var isAddingProject = false
    @Environment(AppEnvironment.self) private var environment

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
        // On the new-chat page the run-picker chips live above the card in
        // this same stack: a fully expanded card leaves them their room at
        // the top rather than growing the stack past `maxHeight`.
        let pickersOverhead = showsRunPickers ? runPickersHeight + 8 : 0
        return max(Self.collapsedMaxEditorHeight, maxHeight - Self.cardChromeHeight - pickersOverhead)
    }

    /// Where the card rests when no drag is in flight.
    private var baseEditorHeight: CGFloat {
        isExpanded ? maxEditorHeight : collapsedEditorHeight
    }

    /// Whichever drag is live — the SwiftUI chrome drag or the editor's
    /// UIKit pan. They are mutually exclusive in practice (one finger), so
    /// this is a straight merge, not a sum.
    private var activeDragTranslation: CGFloat {
        dragTranslation != 0 ? dragTranslation : panTranslation
    }

    private var editorHeight: CGFloat {
        if activeDragTranslation != 0 {
            return min(maxEditorHeight, max(collapsedEditorHeight, baseEditorHeight - activeDragTranslation))
        }
        return releaseHeight ?? baseEditorHeight
    }

    private var placeholder: String {
        controller.isSending ? "Reply while it works" : "Ask for follow-up changes"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The new-chat page chooses where the chat will work from the
            // composer: a project and, for git projects, project directory
            // vs a new worktree. The chips float above the card in one glass
            // group, like the macOS new-chat row; the choice is fixed the
            // moment the first message creates the workspace.
            if showsRunPickers {
                runTargetChips
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .composerGlassSurface(cornerRadius: 18)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: { height in
                        runPickersHeight = height
                    }
            }
            card
        }
        .sheet(isPresented: $isAddingProject) {
            AddProjectSheet { project in
                selectTargetProject(project)
            }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: { height in
            // Publish only the resting size; see `collapsedHeight`.
            if !isExpanded, activeDragTranslation == 0, releaseHeight == nil {
                collapsedHeight = height
            }
        }
        .onAppear { text = controller.composerText }
        // The UIKit editor deliberately owns keystrokes locally, but model-
        // initiated changes (a successful send clearing the draft, or a
        // failed send restoring it) still need to cross that boundary. On a
        // first send this also prevents the newly mounted promotion composer
        // from reconstructing itself with the just-sent text.
        .onChange(of: controller.composerText) { _, newValue in
            if retainsSubmittedTextForPromotion, newValue.isEmpty { return }
            guard text != newValue else { return }
            text = newValue
        }
        .onDisappear {
            if !retainsSubmittedTextForPromotion {
                controller.composerText = text
            }
        }
        // The editor's text lives in local state (see the type comment), so
        // backgrounding must flush it to the controller for the draft
        // persistence path — otherwise swiping the app away loses whatever
        // was typed since the last flush.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            controller.composerText = text
        }
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

    /// The one Liquid Glass card. Its content morphs, macOS-style: a blocking
    /// agent question replaces the composer inside the same surface (no
    /// second card stacked above it), then unfolds back when resolved.
    private var card: some View {
        Group {
            if let question = controller.activeQuestion {
                QuestionCardView(controller: controller, request: question)
                    .id(question.questionId)
                    .transition(Motion.unfold(reduceMotion: reduceMotion, anchor: .bottom))
            } else {
                composerContent
                    .transition(Motion.unfold(reduceMotion: reduceMotion, anchor: .bottom))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .composerGlassSurface(cornerRadius: ComposerGlassStyle.composerCornerRadius)
        // Submission blanket over the whole card, exactly like the macOS
        // composer shell.
        .overlay {
            if controller.activeQuestion != nil, controller.isResolvingQuestion {
                RoundedRectangle(cornerRadius: ComposerGlassStyle.composerCornerRadius)
                    .fill(Color(.systemGroupedBackground).opacity(0.72))
                    .overlay {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Submitting response…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Submitting response")
            }
        }
        .disabled(controller.isResolvingQuestion)
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
                        Color(.systemGroupedBackground),
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
        // The last uncovered stretch of the card: its top padding, above the
        // editor. An invisible grab strip completes grab-anywhere — the
        // editor's UIKit pan covers the text area, the toolbar row covers
        // the bottom, and this covers the strip in between the card's top
        // edge and the first line of text (it ends where the glyphs start,
        // so no text interaction loses its touches). Stands down while an
        // agent question holds the card, like the other resize gestures.
        .overlay(alignment: .top) {
            if controller.activeQuestion == nil {
                Color.clear
                    .frame(height: 16)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .simultaneousGesture(expansionDrag)
            }
        }
        .accessibilityAction(named: isExpanded ? "Collapse composer" : "Expand composer") {
            setExpanded(!isExpanded)
        }
        // Resizing the card shouldn't ripple layout out into the transcript
        // behind it.
        .geometryGroup()
        .animation(
            Motion.quick(reduceMotion: reduceMotion),
            value: controller.activeQuestion?.questionId
        )
    }

    private var composerContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !controller.composerAttachments.isEmpty {
                ComposerAttachmentStrip(controller: controller)
            }

            ZStack(alignment: .topLeading) {
                // A UIKit text view: return inserts newlines, the content
                // height comes straight from the text view (no mirror), and
                // the last line renders — SwiftUI's TextEditor drops it when
                // scrolling is disabled inside a fixed frame.
                ComposerTextView(
                    text: $text,
                    handoffID: textEditorHandoffID,
                    handoffRole: textEditorHandoffRole,
                    // The controller is briefly `isSubmitting` while the
                    // first-send destination mounts. Disabling either UIKit
                    // editor in that interval automatically resigns the
                    // source before focus can transfer and retracts the
                    // keyboard. Promotion editors stay editable through the
                    // atomic responder swap; normal composers keep the
                    // existing submission lock.
                    isEditable: textEditorHandoffRole != .none
                        || !(controller.isSubmitting || controller.isResolvingQuestion),
                    focusRequest: initialFocusRequest,
                    onFocusRequestFulfilled: onInitialFocusRequestFulfilled,
                    onPasteAttachments: handlePastedAttachments,
                    // Scrolling stays off unless the text really overflows,
                    // so a drag on the card is never swallowed by the editor.
                    isScrollEnabled: editorHeight < measuredTextHeight,
                    contentHeight: $measuredTextHeight,
                    // Grab-anywhere, Slack-style: a UIKit pan on the editor
                    // resizes the card, but only when UIKit's own gesture
                    // arbitration says the touch isn't a text interaction
                    // (selection, loupe, scroll). See `expansionPan`.
                    onResizePanChanged: { translation in
                        var live = Transaction()
                        live.disablesAnimations = true
                        withTransaction(live) { panTranslation = translation }
                    },
                    onResizePanEnded: { translation, velocity in
                        endDrag(translation: translation, velocity: velocity)
                    },
                    onResizePanCancelled: {
                        withAnimation(.snappy(duration: 0.28)) { panTranslation = 0 }
                    }
                )
                .frame(height: editorHeight)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    onSendSourceFrameChange?(frame)
                }

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
            .contentShape(Rectangle())
            // The chrome half of grab-anywhere: this SwiftUI drag covers the
            // toolbar row, and the editor's UIKit pan covers the text area
            // (see `HeightReportingTextView.expansionPan`). Simultaneous here
            // only shares touches with the row's own buttons, and a tap
            // never travels the 8pt minimum.
            .simultaneousGesture(expansionDrag)
        }
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
                endDrag(translation: value.translation.height, velocity: value.velocity.height)
            }
    }

    /// Shared release logic for both resize gestures (the SwiftUI chrome
    /// drag and the editor's UIKit pan): snap to fully expanded or collapsed
    /// based on where the gesture was heading.
    private func endDrag(translation: CGFloat, velocity: CGFloat) {
        let base = baseEditorHeight
        let height = min(
            maxEditorHeight,
            max(collapsedEditorHeight, base - translation)
        )
        // A flick commits on velocity alone; otherwise a short pull
        // away from the resting state is enough.
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
        // The live translation zeroes the instant the gesture ends
        // (GestureState resets itself; the pan reset below), which would
        // snap the card back to its old resting height for a frame before
        // the settle animation started. Pin the release height un-animated
        // first, then animate that override away toward the new resting
        // state, so the settle starts exactly where the finger let go.
        var pin = Transaction()
        pin.disablesAnimations = true
        withTransaction(pin) {
            releaseHeight = height
            panTranslation = 0
        }
        isExpanded = shouldExpand
        withAnimation(.snappy(duration: 0.28)) { releaseHeight = nil }
    }

    private func setExpanded(_ expand: Bool) {
        withAnimation(.snappy(duration: 0.28)) {
            isExpanded = expand
        }
    }

    // MARK: - Run chips (new-chat page only)

    /// Projects offered by the picker (scratch backing projects, when a
    /// server has any, are internal and never listed).
    private var pickerProjects: [Project] {
        environment.projectList.activeProjects.filter { !$0.isScratch }
    }

    /// The live project record. The controller holds a snapshot from when
    /// the project was picked; the server's git probe lands on the list
    /// afterwards, and the worktree chip must follow the probed value.
    private var liveProject: Project {
        environment.projectList.projects.first {
            $0.serverId == controller.project.serverId && $0.id == controller.project.id
        } ?? controller.project
    }

    private var runTargetChips: some View {
        HStack(spacing: 10) {
            projectChip
            if liveProject.isGitRepository {
                Divider()
                    .frame(height: 14)
                    .accessibilityHidden(true)
                runLocationChip
            }
        }
    }

    private var projectChip: some View {
        Menu {
            ForEach(pickerProjects) { project in
                Button {
                    selectTargetProject(project)
                } label: {
                    menuRow(
                        project.name,
                        systemImage: project.symbolName,
                        isSelected: controller.project.id == project.id
                    )
                }
            }
            Divider()
            Button {
                isAddingProject = true
            } label: {
                Label("New Project…", systemImage: "folder.badge.plus")
            }
        } label: {
            chipLabel(controller.project.name, systemImage: controller.project.symbolName)
        }
        .accessibilityLabel("Project")
        .accessibilityValue(controller.project.name)
    }

    private var runLocationChip: some View {
        let newWorktree = controller.wantsNewWorktree
        return Menu {
            Button {
                selectRunLocation(newWorktree: false)
            } label: {
                menuRow("Project Directory", systemImage: "folder.fill", isSelected: !newWorktree)
            }
            Button {
                selectRunLocation(newWorktree: true)
            } label: {
                menuRow("New Worktree", systemImage: "arrow.triangle.branch", isSelected: newWorktree)
            }
        } label: {
            chipLabel(
                newWorktree ? "New Worktree" : "Project Directory",
                systemImage: newWorktree ? "arrow.triangle.branch" : "folder.fill"
            )
        }
        .accessibilityLabel("Run location")
        .accessibilityValue(newWorktree ? "New Worktree" : "Project Directory")
    }

    /// A picked project carries the machine's remembered worktree preference
    /// (worktrees only make sense for git projects).
    func selectTargetProject(_ project: Project) {
        environment.composerDefaults.rememberNewWorkspaceProject(
            serverId: project.serverId,
            projectId: project.id
        )
        let prefersWorktree =
            project.isGitRepository
            && environment.composerDefaults.prefersWorktreeForNewWorkspaces(
                forServer: project.serverId
            )
        Task {
            await controller.selectProject(project)
            controller.wantsNewWorktree = prefersWorktree
        }
        // Re-probe git capability so the run-location chip tracks fresh data.
        Task { await environment.projectList.refreshFromServer() }
    }

    private func selectRunLocation(newWorktree: Bool) {
        environment.composerDefaults.rememberNewWorkspaceWorktreePreference(
            serverId: controller.project.serverId,
            createsWorktree: newWorktree
        )
        controller.wantsNewWorktree = newWorktree
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

    /// Routes file and image pasteboard content through the same staging paths
    /// as the attachment menu. The paste delegate consumes these items so it
    /// does not also insert a filename or object-replacement character.
    private func handlePastedAttachments(_ pasted: [PastedAttachment]) {
        for item in pasted {
            switch item {
            case let .fileURL(url):
                ComposerAttachmentStaging.stage(pickedURLs: [url], into: controller)
            case let .image(data, suggestedName):
                controller.attachImageData(data, suggestedName: suggestedName)
            }
        }
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
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .scaledFrame(width: 28, height: 28, relativeTo: .subheadline)
                .expandedHitTarget(base: 28)
        }
        .buttonStyle(.plain)
        .disabled(remainingAttachmentSlots == 0)
        .accessibilityLabel("Attach files")
    }

    private var sendButton: some View {
        Button {
            let outgoing = text
            if preservesFocusAfterSend {
                retainsSubmittedTextForPromotion = true
            }
            onWillSend?(outgoing)
            controller.composerText = outgoing
            if !preservesFocusAfterSend {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                )
            }
            setExpanded(false)
            Task { await controller.send() }
        } label: {
            Image(systemName: "arrow.up")
                .font(.subheadline.weight(.bold))
                .scaledFrame(width: 30, height: 30, relativeTo: .subheadline)
                .foregroundStyle(canSend ? Color(.systemBackground) : Color.secondary.opacity(0.75))
                .background(
                    Circle().fill(
                        canSend ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.16)
                    )
                )
                .expandedHitTarget(base: 30)
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
                .font(.caption.weight(.bold))
                .scaledFrame(width: 30, height: 30, relativeTo: .caption)
                .foregroundStyle(.secondary)
                .background(Circle().fill(Color.secondary.opacity(0.16)))
                .expandedHitTarget(base: 30)
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
                        // Weight + color together carry the hierarchy (HIG:
                        // don't rely on color alone to distinguish levels).
                        Text(model.currentName)
                            .fontWeight(.medium)
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
            Picker(
                option.name,
                selection: Binding(
                    get: { controller.configOptions.first { $0.id == option.id }?.currentValue ?? option.currentValue },
                    set: { value in Task { await controller.setConfigOption(option.id, value) } }
                )
            ) {
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
///
/// `updateUIView` touches the view only when a value really changed. Setting
/// UITextView properties (`text`, `isEditable`) unconditionally on every
/// SwiftUI update — which runs per keystroke — resets the keyboard's
/// autocorrect/prediction state, flickering the assistant bar above the
/// keyboard and breaking the native text-interaction feel.
enum ComposerTextEditorHandoffRole {
    case none
    case promotionSource
    case promotionDestination
}

private struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let handoffID: UUID?
    let handoffRole: ComposerTextEditorHandoffRole
    var isEditable: Bool
    var focusRequest: UUID?
    var onFocusRequestFulfilled: ((UUID) -> Void)?
    var onPasteAttachments: ([PastedAttachment]) -> Void
    var isScrollEnabled: Bool
    @Binding var contentHeight: CGFloat
    var onResizePanChanged: (CGFloat) -> Void
    var onResizePanEnded: (CGFloat, CGFloat) -> Void
    var onResizePanCancelled: () -> Void

    func makeUIView(context: Context) -> ComposerTextViewContainer {
        let container = ComposerTextViewContainer()
        installActivation(on: container, coordinator: context.coordinator)
        container.activateIfPossible()
        return container
    }

    func updateUIView(_ container: ComposerTextViewContainer, context: Context) {
        installActivation(on: container, coordinator: context.coordinator)
        container.activateIfPossible()
    }

    static func dismantleUIView(
        _ container: ComposerTextViewContainer,
        coordinator _: Coordinator
    ) {
        container.activation = nil
        ComposerTextViewHandoffRegistry.release(container)
    }

    private func installActivation(
        on container: ComposerTextViewContainer,
        coordinator: Coordinator
    ) {
        container.activation = { [self, weak container, weak coordinator] in
            guard let container, let coordinator else { return }
            let view: HeightReportingTextView?
            switch handoffRole {
            case .none:
                // The canonical route outlives NewChatFlow. If SwiftUI updates
                // this representable before the coordinator's synchronous
                // settle hook, adopt the existing editor instead of stacking
                // a second local UITextView over it.
                view =
                    container.localEditor
                    ?? ComposerTextViewHandoffRegistry.retirePromotionEditor(
                        ownedBy: container
                    )
                    ?? makeEditor()
                container.localEditor = view
                if let view, view.superview !== container {
                    container.addSubview(view)
                }
            case .promotionSource:
                if let handoffID {
                    view = ComposerTextViewHandoffRegistry.attachSource(
                        id: handoffID,
                        to: container,
                        makeEditor: makeEditor
                    )
                } else {
                    view = container.localEditor ?? makeEditor()
                    container.localEditor = view
                    if let view, view.superview !== container {
                        container.addSubview(view)
                    }
                }
            case .promotionDestination:
                guard let handoffID else { return }
                view = ComposerTextViewHandoffRegistry.attachDestination(
                    id: handoffID,
                    to: container
                )
            }
            guard let view else { return }
            configure(view, coordinator: coordinator)
            container.setNeedsLayout()
        }
    }

    private func makeEditor() -> HeightReportingTextView {
        let view = HeightReportingTextView()
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        view.textContainer.lineFragmentPadding = 0
        // Prompts are code-adjacent — no auto-capitalized first letters.
        view.autocapitalizationType = .none
        // A plain UITextView implicitly accepts only strings. Declare the two
        // attachment representations as pasteable too, then let the paste
        // delegate consume them without inserting rich text into the prompt.
        view.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
            UTType.plainText.identifier,
            UTType.fileURL.identifier,
            UTType.image.identifier,
        ])
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Height flows from the view's own layout, not from updateUIView: a
        // freshly (re)mounted composer has zero width until UIKit lays it
        // out, so measuring during the SwiftUI update reported nothing and a
        // restored draft sat at the minimum height until the next keystroke.
        return view
    }

    private func configure(_ view: HeightReportingTextView, coordinator: Coordinator) {
        view.delegate = coordinator
        view.pasteDelegate = coordinator
        view.onContentHeightChange = { [binding = $contentHeight] height in
            // Defer: layout can run inside a view update.
            Task { @MainActor in
                binding.wrappedValue = height
            }
        }
        // Only push text the view doesn't already have (a restored draft, a
        // send clearing the field) — and never while the keyboard holds an
        // active composition, which a programmatic set would tear down.
        if view.text != text, view.markedTextRange == nil {
            view.text = text
            // The callback defers its binding write, so reporting here —
            // inside a view update — is safe.
            view.reportContentHeight()
        }
        if view.isEditable != isEditable {
            view.isEditable = isEditable
        }
        view.onFocusRequestFulfilled = onFocusRequestFulfilled
        coordinator.onPasteAttachments = onPasteAttachments
        view.requestInitialFocus(focusRequest)
        if view.isScrollEnabled != isScrollEnabled {
            view.isScrollEnabled = isScrollEnabled
        }
        // Closure reassignment never touches keyboard or layout state.
        view.onResizePanChanged = onResizePanChanged
        view.onResizePanEnded = onResizePanEnded
        view.onResizePanCancelled = onResizePanCancelled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onPasteAttachments: onPasteAttachments)
    }

    final class Coordinator: NSObject, UITextViewDelegate, UITextPasteDelegate {
        private let text: Binding<String>
        var onPasteAttachments: ([PastedAttachment]) -> Void

        init(
            text: Binding<String>,
            onPasteAttachments: @escaping ([PastedAttachment]) -> Void
        ) {
            self.text = text
            self.onPasteAttachments = onPasteAttachments
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            (textView as? HeightReportingTextView)?.reportContentHeight()
        }

        /// UIKit supplies item providers only after the user invokes Paste,
        /// preserving the system's paste privacy behavior. Files win over
        /// image previews, matching the macOS composer; plain text delegates
        /// back to UITextView's standard transformation.
        func textPasteConfigurationSupporting(
            _ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
            transform item: any UITextPasteItem
        ) {
            let provider = item.itemProvider
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                item.setNoResult()
                provider.loadObject(ofClass: NSURL.self) { [weak self] object, _ in
                    guard let url = object as? NSURL else { return }
                    Task { @MainActor [weak self] in
                        self?.onPasteAttachments([.fileURL(url as URL)])
                    }
                }
                return
            }
            if provider.canLoadObject(ofClass: UIImage.self) {
                item.setNoResult()
                provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                    guard let image = object as? UIImage,
                        let data = image.pngData()
                    else { return }
                    Task { @MainActor [weak self] in
                        self?.onPasteAttachments([.image(data: data, suggestedName: nil)])
                    }
                }
                return
            }
            item.setDefaultResult()
        }
    }
}

/// SwiftUI owns these stable containers and each promotion surface owns its
/// own editor. Keeping the editor inside its controller hierarchy is required
/// for UIKit to open the software keyboard from a programmatic focus request.
final class ComposerTextViewContainer: UIView {
    var activation: (() -> Void)?
    var localEditor: HeightReportingTextView?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        activateIfPossible()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ComposerTextViewHandoffRegistry.layoutEditor(ownedBy: self)
        subviews.forEach { $0.frame = bounds }
    }

    func activateIfPossible() {
        activation?()
    }
}

/// New Chat's ordinary composer owns an ordinary local UITextView. The
/// registry remembers only weak source/destination ports until Send explicitly
/// begins promotion; only then does one entry temporarily own the concrete
/// first responder. This distinction is what makes dismiss/reopen safe: draft
/// data survives in SessionController, while UIKit presentation state does not.
@MainActor
enum ComposerTextViewHandoffRegistry {
    private final class Ports {
        weak var source: ComposerTextViewContainer?
        weak var destination: ComposerTextViewContainer?
    }

    private final class Entry {
        let editor: HeightReportingTextView
        weak var owner: ComposerTextViewContainer?
        var ownerRole: ComposerTextEditorHandoffRole
        weak var pendingDestination: ComposerTextViewContainer?
        var parkedAlpha: CGFloat?
        var isPortaled = false

        init(
            editor: HeightReportingTextView,
            owner: ComposerTextViewContainer,
            role: ComposerTextEditorHandoffRole
        ) {
            self.editor = editor
            self.owner = owner
            ownerRole = role
        }
    }

    private static var ports: [UUID: Ports] = [:]
    private static var entries: [UUID: Entry] = [:]

    static func attachSource(
        id: UUID,
        to container: ComposerTextViewContainer,
        makeEditor: () -> HeightReportingTextView
    ) -> HeightReportingTextView? {
        // Once Send has transferred this editor into window space, a source
        // reconciliation must not create a replacement underneath the opaque
        // transition surface or steal the responder back from its destination.
        guard entries[id] == nil else { return nil }

        let port = ports[id] ?? Ports()
        port.source = container
        ports[id] = port

        let editor = container.localEditor ?? makeEditor()
        container.localEditor = editor
        if editor.superview !== container {
            container.addSubview(editor)
        }
        editor.frame = container.bounds
        return editor
    }

    static func attachDestination(
        id: UUID,
        to container: ComposerTextViewContainer
    ) -> HeightReportingTextView? {
        let port = ports[id] ?? Ports()
        port.destination = container
        ports[id] = port

        guard let entry = entries[id] else { return nil }
        if entry.ownerRole == .promotionSource {
            entry.pendingDestination = container
            return nil
        }
        entry.owner = container
        place(entry, through: container)
        return entry.editor
    }

    static func release(_ container: ComposerTextViewContainer) {
        var emptyPortIDs: [UUID] = []
        for (id, port) in ports {
            if port.source === container { port.source = nil }
            if port.destination === container { port.destination = nil }
            if port.source == nil, port.destination == nil, entries[id] == nil {
                emptyPortIDs.append(id)
            }
        }
        for id in emptyPortIDs { ports.removeValue(forKey: id) }

        guard let match = entries.first(where: { $0.value.owner === container }) else {
            container.localEditor?.removeFromSuperview()
            container.localEditor = nil
            return
        }
        // Dismantling the modal's source port is the authoritative ownership
        // boundary. The real workspace registered its destination port before
        // dismissal, so transfer geometry/delegate ownership without ever
        // removing the active editor from its stable UIWindow superview.
        if let destination = match.value.pendingDestination,
            destination.window != nil
        {
            place(match.value, through: destination)
            match.value.owner = destination
            match.value.ownerRole = .promotionDestination
            match.value.pendingDestination = nil
            destination.activateIfPossible()
            return
        }
        // A normal composer teardown has no successor and retires its editor.
        match.value.editor.alpha = match.value.parkedAlpha ?? match.value.editor.alpha
        match.value.editor.removeFromSuperview()
        entries.removeValue(forKey: match.key)
        ports.removeValue(forKey: match.key)
        container.localEditor = nil
    }

    /// Explicit terminal cleanup for a native sheet that closed without
    /// sending. Normally there is no active entry at all; this also makes a
    /// cancelled/failed partial handoff idempotently safe.
    static func cancel(_ id: UUID) {
        if let entry = entries.removeValue(forKey: id) {
            entry.editor.alpha = entry.parkedAlpha ?? entry.editor.alpha
            entry.parkedAlpha = nil
            entry.isPortaled = false
            entry.editor.removeFromSuperview()
        }
        ports.removeValue(forKey: id)
    }

    /// Promotion state is transient; its destination view is not. Convert the
    /// registry-owned editor into that same container's ordinary local editor
    /// without changing object identity, focus, or responder chain.
    static func retirePromotionEditor(
        ownedBy container: ComposerTextViewContainer
    ) -> HeightReportingTextView? {
        guard let match = entries.first(where: { $0.value.owner === container }) else {
            return nil
        }
        entries.removeValue(forKey: match.key)
        ports.removeValue(forKey: match.key)
        match.value.pendingDestination = nil
        match.value.editor.alpha = match.value.parkedAlpha ?? match.value.editor.alpha
        match.value.parkedAlpha = nil
        match.value.isPortaled = false
        return match.value.editor
    }

    /// Ends the window portal synchronously at the structural commit. Waiting
    /// for SwiftUI's next representable update leaves a real, interactive text
    /// view above the entire app for at least one reconciliation; a fast tab
    /// change can then expose it over non-chat content. Reparenting the same
    /// responder within the same UIWindow preserves identity while restoring
    /// ordinary ancestor clipping and visibility immediately.
    @discardableResult
    static func settlePromotedEditor(id: UUID) -> Bool {
        guard let entry = entries[id],
            entry.ownerRole == .promotionDestination
                || entry.pendingDestination?.window != nil
        else { return false }

        if entry.ownerRole == .promotionSource,
            let destination = entry.pendingDestination
        {
            entry.owner = destination
            entry.ownerRole = .promotionDestination
        }
        guard let owner = entry.owner else { return false }

        let editor = entry.editor
        entries.removeValue(forKey: id)
        ports.removeValue(forKey: id)
        entry.pendingDestination = nil
        editor.alpha = entry.parkedAlpha ?? editor.alpha
        entry.parkedAlpha = nil
        entry.isPortaled = false
        owner.localEditor = editor
        if editor.superview !== owner {
            owner.addSubview(editor)
        }
        editor.frame = owner.bounds
        owner.setNeedsLayout()
        return editor.superview === owner
    }

    static func layoutEditor(ownedBy container: ComposerTextViewContainer) {
        guard
            let entry = entries.values.first(where: {
                $0.owner === container && $0.isPortaled
            })
        else { return }
        portal(entry, through: container)
    }

    private static func place(
        _ entry: Entry,
        through container: ComposerTextViewContainer
    ) {
        if entry.isPortaled {
            portal(entry, through: container)
        } else {
            contain(entry, in: container)
        }
    }

    /// Ordinary composition stays inside the SwiftUI-owned container so every
    /// native sheet transform, clip, and dismissal gesture applies to the
    /// editor exactly as it does to the rest of the composer.
    private static func contain(
        _ entry: Entry,
        in container: ComposerTextViewContainer
    ) {
        entry.isPortaled = false
        if entry.editor.superview !== container {
            container.addSubview(entry.editor)
        }
        entry.editor.frame = container.bounds
    }

    /// Promotion editors live directly in their one app window only for the
    /// sheet-to-route morph. The settled canonical workspace changes to role
    /// `.none`, and `retirePromotionEditor` immediately returns this exact view
    /// to its composer container before any other pane can become visible.
    private static func portal(_ entry: Entry, through container: ComposerTextViewContainer) {
        guard let window = container.window else { return }
        entry.isPortaled = true
        if entry.editor.superview !== window {
            window.addSubview(entry.editor)
        } else {
            window.bringSubviewToFront(entry.editor)
        }
        entry.editor.frame = container.convert(container.bounds, to: window)
    }

    /// The transition snapshot and message-flight view become the sole visual
    /// owners of the draft while the real editor keeps the keyboard session
    /// alive underneath them. Alpha does not alter responder ownership or the
    /// editor's UIWindow ancestry.
    static func beginStablePortalTransition(id: UUID) -> Bool {
        guard entries[id] == nil,
            let port = ports[id],
            let owner = port.source,
            let editor = owner.localEditor,
            owner.window != nil
        else { return false }
        let entry = Entry(editor: editor, owner: owner, role: .promotionSource)
        entry.pendingDestination = port.destination
        entries[id] = entry
        // Ownership changes only now. Before Send, the editor was an ordinary
        // child of the ordinary sheet composer and could be freely destroyed.
        owner.localEditor = nil
        // Reparent the existing first responder within the same UIWindow at
        // the last possible moment. Before this call it remains a normal sheet
        // descendant; after it, its stable window ancestry survives the
        // sheet-to-route structural swap without retracting the keyboard.
        portal(entry, through: owner)
        if entry.parkedAlpha == nil {
            entry.parkedAlpha = entry.editor.alpha
        }
        entry.editor.alpha = 0.001
        return entry.editor.isFirstResponder
    }

    static func promotedEditor(id: UUID) -> UIView? {
        entries[id]?.ownerRole == .promotionDestination
            ? entries[id]?.editor
            : nil
    }

    /// Change only logical owner, bindings, and window-space frame. The
    /// concrete UITextView stays in the same UIWindow and remains the same
    /// first responder, so UIKit has no reason to end the keyboard session.
    static func completeStablePortalHandoff(id: UUID) -> Bool {
        guard let entry = entries[id],
            entry.ownerRole == .promotionSource,
            entry.pendingDestination?.window != nil,
            let destination = entry.pendingDestination
        else { return false }
        entry.owner = destination
        entry.ownerRole = .promotionDestination
        entry.pendingDestination = nil
        destination.activateIfPossible()
        portal(entry, through: destination)
        entry.editor.alpha = entry.parkedAlpha ?? 1
        entry.parkedAlpha = nil
        return entry.editor.isFirstResponder
    }
}

/// A UITextView that reports its fitting content height whenever layout
/// gives it a real width — including the first layout after being remounted
/// with restored draft text, and any width change thereafter.
///
/// It also carries the composer's grab-anywhere resize pan. Living at the
/// UIKit level, the pan takes part in the text view's own gesture
/// arbitration — unlike a SwiftUI `simultaneousGesture` layered on top,
/// which ran alongside every selection and loupe drag and made text
/// interaction feel non-native. `gestureRecognizerShouldBegin` is the whole
/// contract: begin only for a predominantly vertical pull, never while the
/// text can scroll, and never for a touch sequence a text interaction
/// already owns.
final class HeightReportingTextView: UITextView {
    var onContentHeightChange: ((CGFloat) -> Void)?
    /// The composer's resize pan, reported in window coordinates so the
    /// view's own growth under the finger can't feed back into the
    /// translation.
    var onResizePanChanged: ((CGFloat) -> Void)?
    /// (translation, velocity) at release, points and points/second — the
    /// same units as SwiftUI's DragGesture, so both gestures share one
    /// commit path.
    var onResizePanEnded: ((CGFloat, CGFloat) -> Void)?
    var onResizePanCancelled: (() -> Void)?
    var onFocusRequestFulfilled: ((UUID) -> Void)?

    private var lastReportedHeight: CGFloat = 0
    /// A request can arrive before SwiftUI has inserted this view into a
    /// window. Keep it pending until `didMoveToWindow`, then remember that it
    /// was fulfilled so later updates cannot reopen a dismissed keyboard.
    private var pendingFocusRequest: UUID?
    private var fulfilledFocusRequest: UUID?

    private lazy var expansionPan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleExpansionPan))
        pan.maximumNumberOfTouches = 1
        return pan
    }()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        addGestureRecognizer(expansionPan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func requestInitialFocus(_ request: UUID?) {
        guard let request, request != fulfilledFocusRequest else { return }
        pendingFocusRequest = request
        fulfillPendingFocusRequestIfPossible()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        fulfillPendingFocusRequestIfPossible()
    }

    private func fulfillPendingFocusRequestIfPossible() {
        guard let request = pendingFocusRequest,
            window != nil,
            isEditable
        else { return }
        guard becomeFirstResponder() else { return }
        fulfilledFocusRequest = request
        pendingFocusRequest = nil
        // UIKit may attach during a SwiftUI update. Acknowledge on the next
        // main-actor turn so the source can clear the request safely.
        Task { @MainActor [onFocusRequestFulfilled] in
            onFocusRequestFulfilled?(request)
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === expansionPan else {
            // Text interactions and the scroll pan keep their own rules.
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        // Overflowing text owns vertical drags for scrolling; the card is
        // still grabbable from its toolbar row.
        guard !isScrollEnabled else { return false }
        // Only a predominantly vertical pull reads as a resize; sideways
        // drags stay available to text interactions.
        let velocity = expansionPan.velocity(in: self)
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        // Never steal a touch sequence a text gesture already owns — an
        // active loupe drag or selection-handle drag keeps the card still.
        let textGestureActive = (gestureRecognizers ?? []).contains { other in
            other !== expansionPan && (other.state == .began || other.state == .changed)
        }
        return !textGestureActive
    }

    @objc private func handleExpansionPan(_ pan: UIPanGestureRecognizer) {
        let space = window ?? self
        switch pan.state {
        case .changed:
            onResizePanChanged?(pan.translation(in: space).y)
        case .ended:
            onResizePanEnded?(pan.translation(in: space).y, pan.velocity(in: space).y)
        case .cancelled, .failed:
            onResizePanCancelled?()
        default:
            break
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportContentHeight()
    }

    func reportContentHeight() {
        let width = bounds.width
        guard width > 0 else { return }
        let height = sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        guard abs(height - lastReportedHeight) > 0.5 else { return }
        lastReportedHeight = height
        onContentHeightChange?(height)
    }
}
