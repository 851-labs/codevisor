import ACPKit
import CodevisorCore
import CodevisorUI
import PhotosUI
import SwiftUI

/// The iOS composer, matching the macOS composer's structure: the input on its
/// own line with the toolbar row beneath it (attach, model, parameters,
/// then stop/send), all inside one Liquid Glass card.
///
/// While the editor isn't focused the card folds into a one-line preview —
/// the start of the draft, an attachment count, and send — so the transcript
/// gets the room back while the user reads. Tapping it focuses the editor
/// and unfolds the full composer. Dragged fully open, the card turns opaque
/// so long drafts stay legible over the transcript.
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
  @Environment(\.theme) var theme

  var cardStyle = ComposerCardStyle()

  @State var text = ""
  /// The UIKit editor reports its UTF-16 selection so slash commands can
  /// replace the token at the caret without disturbing the rest of a draft.
  @State var selection = NSRange(location: 0, length: 0)
  /// The command palette floats above the composer, so its rendered height
  /// drives the same explicit upward offset used by the macOS composer.
  @State var slashMenuContentHeight: CGFloat = 0
  /// Measured height of the text itself, used for the collapsed size and as
  /// the starting point of a drag.
  @State private var measuredTextHeight: CGFloat = 0
  /// Measured height of the run-picker chip row (new-chat page only), so
  /// an expanded card stops below it instead of shoving it under the bar.
  @State private var runPickersHeight: CGFloat = 0
  /// The toolbar row's rendered height (its controls' hit targets set it).
  @State private var toolbarHeight: CGFloat = 44
  /// Attachments share the card's height budget with the editor.
  @State private var attachmentStripHeight: CGFloat = 0
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
  @State var managedProject: Project?
  @State var showsMachineSettings = false
  /// Only the latest queued target selection starts preparing the draft.
  @State var runTargetSelectionRevision = 0
  /// Paste-provider failures have no attachment bytes left to anchor a
  /// status to. Keep their recovery beside this composer instead of using
  /// the session's connection/error channel.
  @State var pasteFailureNotice: ComposerPasteFailureNotice?
  @State var pasteFailureNoticeHeight: CGFloat = 0
  /// Nil until the UIKit editor first reports, so a composer mounting
  /// around an already-focused editor (first-send promotion) never flashes
  /// its compact preview.
  @State var isEditorFocused: Bool?
  /// Tapping the compact preview focuses the editor through the same
  /// one-shot request as New Chat's initial focus.
  @State var previewFocusRequest: UUID?
  /// A touch that began on the card is down (reported only inside a sheet).
  @State private var isTouchingCardInSheet = false
  /// Editing from the goal accessory requests focus through the same
  /// one-shot UIKit bridge as initial New Chat focus, without making
  /// ordinary view updates reclaim the keyboard.
  @State var goalEditFocusRequest: UUID?
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
      && controller.isServerReady
      && (controller.isConnected || controller.selectedHarness != nil)
      && !controller.composerAttachments.contains { $0.state == .loading }
      && !isClearingGoal
      && controller.configurationValidationState == .ready
  }

  /// The editor's frame reaches up through the card's top padding to its
  /// edge, and the text view insets its text by the same amount. Text sits
  /// where it always did, but a selection handle above the first line
  /// stays inside the text view, where UIKit can hit-test it.
  static let editorTopBleed = ComposerCardStyle.contentPadding
  private static let minEditorHeight: CGFloat = 30 + editorTopBleed
  private static let collapsedMaxEditorHeight: CGFloat = 148 + editorTopBleed
  private static let contentSpacing: CGFloat = 10
  // The picker's invisible tap area already adds 6 points below its glass.
  private static let runPickerSpacing: CGFloat = 2
  /// Chrome around the editor inside the card: paddings, the toolbar row,
  /// and the spacing between them. The row is measured, so a fully
  /// expanded card fills exactly the height it is offered.
  private var cardChromeHeight: CGFloat {
    ComposerCardStyle.contentPadding * 2 - Self.editorTopBleed + Self.contentSpacing
      + toolbarHeight
  }

  /// New Chat's project/run-location chips step aside while the card is
  /// fully expanded, giving the draft the whole sheet.
  private var showsRunPickerRow: Bool {
    showsRunPickers && !isExpanded
  }

  /// `measuredTextHeight` is the text view's own content height (insets
  /// included), reported by the UIKit editor — no mirror, no guessing.
  private var collapsedEditorHeight: CGFloat {
    min(max(measuredTextHeight, Self.minEditorHeight), Self.collapsedMaxEditorHeight)
  }

  private var maxEditorHeight: CGFloat {
    // On the new-chat page the run-picker chips live above the card in
    // this same stack: a fully expanded card leaves them their room at
    // the top rather than growing the stack past `maxHeight`.
    let pickersOverhead = showsRunPickerRow ? runPickersHeight + Self.runPickerSpacing : 0
    let noticeOverhead = pasteFailureNotice == nil ? 0 : pasteFailureNoticeHeight + 8
    // Without this reservation, expanding a draft with attachments makes
    // the card outgrow its host, which reports ever-larger available heights.
    let attachmentOverhead =
      controller.composerAttachments.isEmpty ? 0 : attachmentStripHeight + Self.contentSpacing
    return max(
      Self.collapsedMaxEditorHeight,
      maxHeight - cardChromeHeight - pickersOverhead - noticeOverhead - attachmentOverhead
    )
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

  /// Position the root-level overlay from the card's top edge. Keeping the
  /// overlay at the root gives it a higher z-order than the run pickers;
  /// using the card edge makes the palette cover those chips while open.
  private var slashPaletteOffset: CGFloat {
    let pickersHeight = showsRunPickerRow ? runPickersHeight + Self.runPickerSpacing : 0
    let noticeHeight = pasteFailureNotice == nil ? 0 : pasteFailureNoticeHeight + 8
    let cardTop = pickersHeight + noticeHeight
    return cardTop - slashPaletteHeight - ComposerGlassStyle.clusterSpacing
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Self.runPickerSpacing) {
      // The new-chat page chooses where the chat will work from the
      // composer: a project and, for git projects, project directory
      // vs a new worktree. The chips float above the card in one glass
      // group, like the macOS new-chat row; the choice is fixed the
      // moment the first message creates the workspace.
      if showsRunPickerRow {
        if showsSlashCommandPopup {
          // Liquid Glass may remain visible in its own compositing
          // pass even at zero opacity. Remove the controls entirely
          // while retaining their measured layout slot so the
          // palette can occupy it without moving the composer.
          Color.clear
            .frame(height: runPickersHeight)
            .accessibilityHidden(true)
        } else {
          runTargetControls
            .onGeometryChange(for: CGFloat.self) {
              $0.size.height
            } action: { height in
              runPickersHeight = height
            }
            .transition(.opacity)
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        pasteFailureRail
        card
      }
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
    .animation(Motion.quick(reduceMotion: reduceMotion), value: pasteFailureNotice)
    .onDrop(of: Self.droppableTypes, isTargeted: nil) { acceptDrop($0) }
    .preference(
      key: ComposerBlocksSheetDismissPreferenceKey.self,
      value: isTouchingCardInSheet || isExpanded
    )
    .sheet(isPresented: $showsMachineSettings) {
      SettingsSheet(initialDestination: .machines(focusedMachineID: nil))
    }
    .sheet(item: $managedProject) { project in
      ManageProjectSheet(
        project: project,
        client: environment.machines.client(for: project.serverId),
        didUpdate: { await environment.projectList.refreshFromServer() },
        onDelete: { deleteManagedProject(project) }
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
    #if DEBUG || NAVIGATION_DIAGNOSTICS
      .onReceive(
        NotificationCenter.default.publisher(for: .codevisorDiagnosticSubmitComposer)
      ) { _ in
        // Only the composer that actually holds the draft text sends;
        // prewarmed and replica composers are empty.
        guard !text.isEmpty else { return }
        submitComposer()
      }
    #endif
    // The UIKit editor deliberately owns keystrokes locally, but model-
    // initiated changes (a successful send clearing the draft, or a
    // failed send restoring it) still need to cross that boundary.
    .onChange(of: controller.composerText) { _, newValue in
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
      controller.composerText = text
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
}

extension ComposerBar {

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
    .padding(ComposerCardStyle.contentPadding)
    // Text scrolling up through the editor's top bleed must stop at the
    // card's rounded edge.
    .clipShape(cardStyle.shape)
    // Fully expanded, the draft covers most of the transcript. An opaque
    // fill inside the glass keeps it legible while the glass keeps its
    // identity, so collapsing fades straight back to clear material.
    .background {
      cardStyle.shape
        .fill(expandedSurfaceColor)
        .opacity(isExpanded ? 1 : 0)
        .allowsHitTesting(false)
    }
    .composerGlassSurface(
      shape: cardStyle.shape,
      id: .composer,
      in: glassNamespace
    )
    // Generic questions keep the submission blanket. Deterministic
    // browser selection stays mounted and reports progress on its
    // explicit Continue button.
    .overlay {
      QuestionResolutionOverlay(controller: controller, shape: cardStyle.shape)
    }
    .disabled(controller.isResolvingQuestion)
    .contentShape(Rectangle())
    // In the New Chat sheet, drags that start on the card belong to the
    // composer, never to the sheet's swipe-to-dismiss.
    .background {
      SheetGestureShield { touching in
        isTouchingCardInSheet = touching
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
    VStack(alignment: .leading, spacing: isCompact ? 0 : Self.contentSpacing) {
      if !isCompact, !controller.composerAttachments.isEmpty {
        ComposerAttachmentStrip(controller: controller)
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: { height in
            attachmentStripHeight = height
          }
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
          // Never disable the editor for a send in flight: turning
          // `isEditable` off resigns first responder and retracts the
          // keyboard (on a first send, exactly as the promoted route
          // reconciles). Typing during a send is fine — the send button
          // and `send()`'s own guard prevent a second submission.
          isEditable: textEditorHandoffRole != .none
            || !(controller.isResolvingQuestion || isClearingGoal),
          focusRequest: goalEditFocusRequest ?? initialFocusRequest ?? previewFocusRequest,
          onFocusRequestFulfilled: fulfillFocusRequest,
          onPasteAttachmentEvent: handlePasteAttachmentEvent,
          isComposerExpanded: isExpanded,
          contentHeight: $measuredTextHeight,
          onFocusChange: updateEditorFocus,
          // Grab-anywhere, Slack-style: the editor's own scroll pan
          // scrolls overflowing text, then resizes the card once the
          // text reaches its edge. See `HeightReportingTextView`.
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
          },
          // The send button's own gate: Return with nothing sendable is inert.
          onHardwareReturn: {
            if canSend { submitOrAcceptSlashCommand() }
          }
        )
        // The compact preview keeps the one UIKit editor mounted —
        // its focus, selection, and promotion handoff depend on that
        // identity — but folds it away behind the preview row.
        .frame(height: isCompact ? 0 : editorHeight)
        .opacity(isCompact ? 0 : 1)
        // Only the incoming content fades: folding drops the editor at
        // once (the preview fades in), so the two texts never crossfade
        // at different positions while the glass resizes.
        .animation(isCompact ? nil : compactMorphAnimation, value: isCompact)
        .allowsHitTesting(!isCompact)
        .accessibilityHidden(isCompact)
        .onGeometryChange(for: CGRect.self) { proxy in
          // The send animation starts from the text, not the bleed.
          let frame = proxy.frame(in: .global)
          return CGRect(
            x: frame.minX,
            y: frame.minY + Self.editorTopBleed,
            width: frame.width,
            height: max(0, frame.height - Self.editorTopBleed)
          )
        } action: { frame in
          // The compact preview reports its own text as the source.
          guard !isCompact else { return }
          onSendSourceFrameChange?(frame)
        }

        if text.isEmpty, !isCompact {
          Text("Do something")
            .foregroundStyle(.tertiary)
            .padding(.top, 4 + Self.editorTopBleed)
            .allowsHitTesting(false)
            .transition(composerModeTransition)
        }
      }
      .padding(.top, isCompact ? 0 : -Self.editorTopBleed)

      if isCompact {
        compactPreviewRow
          .font(.callout)
          .transition(composerModeTransition)
      } else {
        composerToolbar
          .font(.callout)
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: { height in
            toolbarHeight = height
          }
          .contentShape(Rectangle())
          .animation(
            Motion.quick(reduceMotion: reduceMotion),
            value: controller.isGoalEditing
          )
          // The chrome half of grab-anywhere: this SwiftUI drag covers the
          // toolbar row, and the editor's scroll pan covers the text area
          // (see `HeightReportingTextView`). Simultaneous here only shares
          // touches with the row's own buttons, and a tap never travels
          // the 8pt minimum.
          .simultaneousGesture(expansionDrag)
          .transition(composerModeTransition)
      }
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
