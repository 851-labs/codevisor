import ACPKit
import CodevisorCore
import CodevisorUI
import PhotosUI
import SwiftUI

struct ComposerBar: View {
  @Bindable var controller: SessionController
  let maxHeight: CGFloat
  @Binding var collapsedHeight: CGFloat
  @Binding var isExpanded: Bool
  var showsRunPickers: Bool = false
  var initialFocusRequest: UUID? = nil
  var onInitialFocusRequestFulfilled: ((UUID) -> Void)? = nil
  var preservesFocusAfterSend = false
  var textEditorHandoffRole: ComposerTextEditorHandoffRole = .none
  var textEditorHandoffID: UUID? = nil
  var sendAnimationsStarted = 0
  var glassNamespace: Namespace.ID? = nil
  var onSendSourceFrameChange: ((CGRect) -> Void)? = nil
  var onWillSend: ((String) -> Void)? = nil

  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.clientControlId) var clientControlId

  var cardStyle = ComposerCardStyle()

  @State var text = ""
  @State var selection = NSRange(location: 0, length: 0)
  @State var pendingTextEdit: ComposerTextEdit?
  @State var slashMenuContentHeight: CGFloat = 0
  @State private var measuredTextHeight: CGFloat = 0
  @State private var runPickersHeight: CGFloat = 0
  @State private var toolbarHeight: CGFloat = 44
  @State private var attachmentStripHeight: CGFloat = 0
  @GestureState private var dragTranslation: CGFloat = 0
  @State private var panTranslation: CGFloat = 0
  @State private var releaseHeight: CGFloat?
  @State private var photoItems: [PhotosPickerItem] = []
  @State var isPickingPhotos = false
  @State var isPickingFiles = false
  @State var isCapturingPhoto = false
  @State var managedProject: Project?
  @State var showsMachineSettings = false
  @State var runTargetSelectionRevision = 0
  @State var pasteFailureNotice: ComposerPasteFailureNotice?
  @State var pasteFailureNoticeHeight: CGFloat = 0
  @State var isEditorFocused: Bool?
  @State var holdsFoldUntilFlight = false
  @State var previewFocusRequest: UUID?
  @Namespace var composerMorph
  @State private var isTouchingCardInSheet = false
  @State var goalEditFocusRequest: UUID?
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
      && !controller.requiresModelSelection
  }

  nonisolated static let editorTopBleed = ComposerCardStyle.contentPadding
  private static let minEditorHeight: CGFloat = 30 + editorTopBleed
  private static let collapsedMaxEditorHeight: CGFloat = 148 + editorTopBleed
  private static let contentSpacing: CGFloat = 10
  private static let runPickerSpacing: CGFloat = 2
  private var cardChromeHeight: CGFloat {
    ComposerCardStyle.contentPadding * 2 - Self.editorTopBleed + Self.contentSpacing
      + toolbarHeight
  }

  private var showsRunPickerRow: Bool {
    showsRunPickers && !isExpanded
  }

  private var collapsedEditorHeight: CGFloat {
    min(max(measuredTextHeight, Self.minEditorHeight), Self.collapsedMaxEditorHeight)
  }

  private var maxEditorHeight: CGFloat {
    let pickersOverhead = showsRunPickerRow ? runPickersHeight + Self.runPickerSpacing : 0
    let noticeOverhead = pasteFailureNotice == nil ? 0 : pasteFailureNoticeHeight + 8
    let attachmentOverhead =
      controller.composerAttachments.isEmpty ? 0 : attachmentStripHeight + Self.contentSpacing
    return max(
      Self.collapsedMaxEditorHeight,
      maxHeight - cardChromeHeight - pickersOverhead - noticeOverhead - attachmentOverhead
    )
  }

  private var questionContentMaxHeight: CGFloat {
    let noticeOverhead = pasteFailureNotice == nil ? 0 : pasteFailureNoticeHeight + 8
    return maxHeight - ComposerCardStyle.contentPadding * 2 - noticeOverhead
  }

  private var baseEditorHeight: CGFloat {
    isExpanded ? maxEditorHeight : collapsedEditorHeight
  }

  private var activeDragTranslation: CGFloat {
    dragTranslation != 0 ? dragTranslation : panTranslation
  }

  private var editorHeight: CGFloat {
    if activeDragTranslation != 0 {
      return min(maxEditorHeight, max(collapsedEditorHeight, baseEditorHeight - activeDragTranslation))
    }
    return releaseHeight ?? baseEditorHeight
  }

  private var slashPaletteOffset: CGFloat {
    let pickersHeight = showsRunPickerRow ? runPickersHeight + Self.runPickerSpacing : 0
    let noticeHeight = pasteFailureNotice == nil ? 0 : pasteFailureNoticeHeight + 8
    let cardTop = pickersHeight + noticeHeight
    return cardTop - slashPaletteHeight - ComposerGlassStyle.clusterSpacing
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Self.runPickerSpacing) {
      if showsRunPickerRow {
        if showsSlashCommandPopup {
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
    .overlay(alignment: .top) {
      if controller.activeQuestion == nil, showsSlashCommandPopup {
        slashCommandPopup
          .offset(y: slashPaletteOffset)
          .zIndex(1)
      }
    }
    .animation(Motion.quick(reduceMotion: reduceMotion), value: showsSlashCommandPopup)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: pasteFailureNotice)
    .onDrop(of: Self.droppableTypes, isTargeted: nil) { acceptDrop($0) }
    .onAppear(perform: adoptHandedOffEditorFocus)
    .onChange(of: sendAnimationsStarted) { releaseFoldHold() }
    .task(id: holdsFoldUntilFlight) {
      guard holdsFoldUntilFlight else { return }
      try? await Task.sleep(for: .seconds(1))
      releaseFoldHold()
    }
    .preference(
      key: ComposerBlocksSheetDismissPreferenceKey.self,
      value: isTouchingCardInSheet || isExpanded
    )
    .sheet(isPresented: $showsMachineSettings) {
      SettingsSheet(initialDestination: .machines(focusedMachineID: nil))
    }
    .sheet(item: $managedProject) { project in
      ProjectSettingsSheet(groupId: ProjectGroup.routeID(for: project), onDeleted: projectDeleted)
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
        guard !text.isEmpty else { return }
        submitComposer()
      }
    #endif
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
    .onChange(of: slashToken == nil) { _, isClosed in
      if !isClosed { controller.refreshCodevisorSkills() }
    }
    .onChange(of: showsSlashCommandPopup) { _, isVisible in
      if !isVisible {
        slashMenuContentHeight = 0
      }
    }
    .onDisappear {
      controller.composerText = text
    }
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

  private var card: some View {
    Group {
      if let question = controller.activeQuestion {
        QuestionCardView(
          controller: controller,
          request: question,
          maxHeight: questionContentMaxHeight
        )
        .id(question.questionId)
        .transition(Motion.unfold(reduceMotion: reduceMotion, anchor: .bottom))
      } else {
        composerContent
          .transition(Motion.unfold(reduceMotion: reduceMotion, anchor: .bottom))
      }
    }
    .padding(ComposerCardStyle.contentPadding)
    .clipShape(cardStyle.shape)
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
    .disabled(controller.isResolvingQuestion)
    .contentShape(Rectangle())
    .background {
      SheetGestureShield { touching in
        isTouchingCardInSheet = touching
      }
    }
    .accessibilityAction(named: isExpanded ? "Collapse composer" : "Expand composer") {
      setExpanded(!isExpanded)
    }
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
        ComposerTextView(
          text: $text,
          selection: $selection,
          pendingEdit: pendingTextEdit,
          handoffID: textEditorHandoffID,
          handoffRole: textEditorHandoffRole,
          isEditable: textEditorHandoffRole != .none
            || !(controller.isResolvingQuestion || isClearingGoal),
          focusRequest: goalEditFocusRequest ?? initialFocusRequest ?? previewFocusRequest,
          onFocusRequestFulfilled: fulfillFocusRequest,
          onPasteAttachmentEvent: handlePasteAttachmentEvent,
          isComposerExpanded: isExpanded,
          contentHeight: $measuredTextHeight,
          onFocusChange: updateEditorFocus,
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
          onHardwareReturn: {
            if canSend { submitOrAcceptSlashCommand() }
          }
        )
        .frame(height: isCompact ? 0 : editorHeight)
        .animation(editorFadeAnimation) { $0.opacity(isCompact ? 0 : 1) }
        .allowsHitTesting(!isCompact)
        .accessibilityHidden(isCompact)
        .onGeometryChange(for: CGRect?.self) { [isCompact] proxy in
          guard !isCompact else { return nil }
          let frame = proxy.frame(in: .global)
          return CGRect(
            x: frame.minX,
            y: frame.minY + Self.editorTopBleed,
            width: frame.width,
            height: max(0, frame.height - Self.editorTopBleed)
          )
        } action: { frame in
          guard let frame else { return }
          onSendSourceFrameChange?(frame)
        }

        if !isCompact {
          Text(controller.composerPlaceholder)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .opacity(text.isEmpty ? 1 : 0)
            .matchedGeometryEffect(
              id: ComposerMorphID.firstLine,
              in: composerMorph,
              properties: .position,
              anchor: .leading
            )
            .padding(.top, 4 + Self.editorTopBleed)
            .allowsHitTesting(false)
            .accessibilityHidden(!text.isEmpty)
            .transition(
              .asymmetric(
                insertion: .opacity.animation(editorFadeAnimation),
                removal: .opacity.animation(compactFade(duration: 0.08))
              ))
        }
      }
      .padding(.top, isCompact ? 0 : -Self.editorTopBleed)

      composerToolbar
        .font(.callout)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: { height in
          guard !isCompact else { return }
          toolbarHeight = height
        }
        .contentShape(Rectangle())
        .animation(
          Motion.quick(reduceMotion: reduceMotion),
          value: controller.isGoalEditing
        )
        .simultaneousGesture(expansionDrag, including: isCompact ? .subviews : .all)
    }
  }

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
        if isCompact {
          compactPreviewLine
            .transition(compactPreviewTransition)
          if !controller.composerAttachments.isEmpty {
            compactAttachmentCount
              .transition(compactChipsTransition)
          }
        } else {
          HStack(spacing: 10) {
            ModelConfigChip(controller: controller)
            if controller.hasPlanMode, controller.isPlanModeOn {
              planModeChip
            }
            if controller.canEditGoal, controller.isGoalComposerArmed {
              goalModeChip
            }
          }
          .transition(compactChipsTransition)
          Spacer(minLength: 0)
        }
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

  private var expansionDrag: some Gesture {
    DragGesture(minimumDistance: 8, coordinateSpace: .global)
      .updating($dragTranslation) { value, translation, transaction in
        transaction.disablesAnimations = true
        translation = value.translation.height
      }
      .onEnded { value in
        endDrag(translation: value.translation.height, velocity: value.velocity.height)
      }
  }

  private func endDrag(translation: CGFloat, velocity: CGFloat) {
    let base = baseEditorHeight
    let height = min(
      maxEditorHeight,
      max(collapsedEditorHeight, base - translation)
    )
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
