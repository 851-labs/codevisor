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
    /// Supplied by the session's one bottom-chrome GlassEffectContainer so
    /// the composer and its accessories animate as a coordinated material
    /// group. Standalone previews can omit it.
    var glassNamespace: Namespace.ID? = nil
    /// Window-space editor bounds are the animation's real source geometry.
    var onSendSourceFrameChange: ((CGRect) -> Void)? = nil
    /// Captured before the controller clears its durable draft. New Chat uses
    /// this to give the outgoing text one visual owner during sheet promotion.
    var onWillSend: ((String) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State var text = ""
    /// The UIKit editor reports its UTF-16 selection so slash commands can
    /// replace the token at the caret without disturbing the rest of a draft.
    @State var selection = NSRange(location: 0, length: 0)
    /// The command palette floats above the composer, so its rendered height
    /// drives the same explicit upward offset used by the macOS composer.
    @State var slashMenuContentHeight: CGFloat = 0
    /// The source New Chat editor keeps drawing the submitted glyphs until
    /// the promotion layer has covered it. The durable controller draft is
    /// already empty, so newly mounted destination composers remain empty.
    @State var retainsSubmittedTextForPromotion = false
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
    @State var isPickingPhotos = false
    @State var isPickingFiles = false
    @State var isCapturingPhoto = false
    @State var isAddingProject = false
    @State var managedProject: Project?
    /// Editing from the goal accessory requests focus through the same
    /// one-shot UIKit bridge as initial New Chat focus, without making
    /// ordinary view updates reclaim the keyboard.
    @State private var goalEditFocusRequest: UUID?
    /// Clearing remains a deliberate destructive action even though goal
    /// editing now opens directly in the composer instead of through a sheet.
    @State var isConfirmingGoalClear = false
    @State var isClearingGoal = false
    @State var goalClearError: String?
    @Environment(AppEnvironment.self) var environment

    var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSend: Bool {
        (controller.isGoalComposerArmed
            ? !trimmed.isEmpty
            : !trimmed.isEmpty || !controller.composerAttachments.isEmpty)
            && !controller.isSubmitting
            && !controller.isConnecting
            && !isClearingGoal
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
        return controller.isSending ? "Reply while it works" : "Ask for follow-up changes"
    }

    /// Position the root-level overlay from the card's top edge. Keeping the
    /// overlay at the root gives it a higher z-order than the run pickers;
    /// using the card edge makes the palette cover those chips while open.
    private var slashPaletteOffset: CGFloat {
        let cardTop = showsRunPickers ? runPickersHeight + 8 : 0
        return cardTop - slashPaletteHeight - ComposerGlassStyle.clusterSpacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The new-chat page chooses where the chat will work from the
            // composer: a project and, for git projects, project directory
            // vs a new worktree. The chips float above the card in one glass
            // group, like the macOS new-chat row; the choice is fixed the
            // moment the first message creates the workspace.
            if showsRunPickers {
                if showsSlashCommandPopup {
                    // Liquid Glass may remain visible in its own compositing
                    // pass even at zero opacity. Remove the controls entirely
                    // while retaining their measured layout slot so the
                    // palette can occupy it without moving the composer.
                    Color.clear
                        .frame(height: runPickersHeight)
                        .accessibilityHidden(true)
                } else {
                    runTargetChips
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .composerGlassSurface(
                            cornerRadius: 18,
                            id: .newChatConfiguration,
                            in: glassNamespace
                        )
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: { height in
                            runPickersHeight = height
                        }
                }
            }
            card
        }
        // The root-level overlay always draws above both children. On New
        // Chat it is positioned from the card, intentionally covering the
        // project/run-location chips while the command palette is open.
        .overlay(alignment: .top) {
            if controller.activeQuestion == nil, showsSlashCommandPopup {
                slashCommandPopup
                    .offset(y: slashPaletteOffset)
                    .zIndex(1)
            }
        }
        // Apple’s glass transition owns the palette's insertion/removal.
        // This value changes only at the visible/hidden boundary, so ordinary
        // query filtering swaps rows immediately while filtering to zero (or
        // back from zero) still morphs the glass out of/into the composer.
        .animation(Motion.quick(reduceMotion: reduceMotion), value: showsSlashCommandPopup)
        .sheet(isPresented: $isAddingProject) {
            AddProjectSheet { project in
                selectTargetProject(project)
            }
        }
        .sheet(item: $managedProject) { project in
            ManageProjectSheet(
                project: project,
                client: environment.machines.client(for: project.serverId),
                didUpdate: { await environment.projectList.refreshFromServer() },
                onArchive: { archiveManagedProject(project) }
            )
        }
        .alert(
            "Clear this goal?",
            isPresented: $isConfirmingGoalClear
        ) {
            Button("Clear Goal", role: .destructive) {
                clearGoalFromComposer()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let objective = controller.goal?.objective ?? controller.draftGoal?.objective ?? text
            Text("The agent stops working toward “\(objective)”.")
        }
        .alert(
            "Couldn't Clear Goal",
            isPresented: Binding(
                get: { goalClearError != nil },
                set: { if !$0 { goalClearError = nil } }
            )
        ) {
            Button("OK") { goalClearError = nil }
        } message: {
            Text(goalClearError ?? "Please try again.")
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: { height in
            // Publish only the resting size; see `collapsedHeight`.
            if !isExpanded, activeDragTranslation == 0, releaseHeight == nil {
                collapsedHeight = height
            }
        }
        .onAppear {
            text = controller.composerText
            selection = NSRange(
                location: (controller.composerText as NSString).length,
                length: 0
            )
        }
        // The UIKit editor deliberately owns keystrokes locally, but model-
        // initiated changes (a successful send clearing the draft, or a
        // failed send restoring it) still need to cross that boundary. On a
        // first send this also prevents the newly mounted promotion composer
        // from reconstructing itself with the just-sent text.
        .onChange(of: controller.composerText) { _, newValue in
            if retainsSubmittedTextForPromotion, newValue.isEmpty { return }
            guard text != newValue else { return }
            text = newValue
            selection = NSRange(location: (newValue as NSString).length, length: 0)
        }
        .onChange(of: controller.isGoalEditing) { _, isEditing in
            if isEditing {
                setExpanded(false)
                goalEditFocusRequest = UUID()
            } else {
                goalEditFocusRequest = nil
            }
        }
        .onChange(of: showsSlashCommandPopup) { _, isVisible in
            // A dismissed menu must not retain the previous query's measured
            // height. Its next glass emergence starts from the correct
            // estimated geometry for the newly visible options.
            if !isVisible {
                slashMenuContentHeight = 0
            }
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
        .composerGlassSurface(
            cornerRadius: ComposerGlassStyle.composerCornerRadius,
            id: .composer,
            in: glassNamespace
        )
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
                    selection: $selection,
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
                        || !(controller.isSubmitting
                            || controller.isResolvingQuestion
                            || isClearingGoal),
                    focusRequest: goalEditFocusRequest ?? initialFocusRequest,
                    onFocusRequestFulfilled: fulfillFocusRequest,
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

            composerToolbar
                .font(.callout)
                .contentShape(Rectangle())
                .animation(
                    Motion.quick(reduceMotion: reduceMotion),
                    value: controller.isGoalEditing
                )
                // The chrome half of grab-anywhere: this SwiftUI drag covers the
                // toolbar row, and the editor's UIKit pan covers the text area
                // (see `HeightReportingTextView.expansionPan`). Simultaneous here
                // only shares touches with the row's own buttons, and a tap
                // never travels the 8pt minimum.
                .simultaneousGesture(expansionDrag)
        }
    }

    /// Goal editing and ordinary composition occupy the same toolbar slot.
    /// Remove the outgoing chrome immediately so SwiftUI never crossfades two
    /// interactive rows on top of each other; only the replacement row fades
    /// in. The UIKit editor above stays mounted, preserving focus and
    /// selection through the mode change.
    @ViewBuilder
    private var composerToolbar: some View {
        if controller.isGoalEditing {
            HStack(spacing: 10) {
                goalEditCancelButton
                Spacer(minLength: 0)
                clearGoalButton
                sendButton
            }
            .transition(composerModeTransition)
        } else {
            HStack(spacing: 10) {
                attachButton
                ModelConfigChip(controller: controller)
                ForEach(controller.pickerOptions) { option in
                    ConfigChip(controller: controller, option: option)
                }
                if controller.hasPlanMode, controller.isPlanModeOn {
                    planModeChip
                }
                if controller.canEditGoal, controller.isGoalComposerArmed {
                    goalModeChip
                }
                Spacer(minLength: 0)
                // Mirrors the macOS toolbar: while the agent runs, stop
                // takes the send slot; a draft brings send back beside it.
                HStack(spacing: 6) {
                    if controller.isSending {
                        stopButton
                        if !trimmed.isEmpty { sendButton }
                    } else {
                        sendButton
                    }
                }
            }
            .transition(composerModeTransition)
        }
    }

    private var composerModeTransition: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .identity)
    }

    private func fulfillFocusRequest(_ request: UUID) {
        if goalEditFocusRequest == request {
            goalEditFocusRequest = nil
        } else {
            onInitialFocusRequestFulfilled?(request)
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

    func setExpanded(_ expand: Bool) {
        withAnimation(.snappy(duration: 0.28)) {
            isExpanded = expand
        }
    }
}
