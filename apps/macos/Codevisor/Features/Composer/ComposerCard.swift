import SwiftUI
import AppKit
import CodevisorCore
import ACPKit
import CodevisorUI
import UniformTypeIdentifiers

struct ComposerCard: View {
  private var cardStyle = ComposerCardStyle()

  @Bindable var controller: SessionController
  var onTextViewReady: ((SubmittingTextView) -> Void)? = nil
  var focus: TerminalFocusController? = nil
  var focusChatId: UUID? = nil
  var glassNamespace: Namespace.ID? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isAppUpdateInProgress) private var isAppUpdateInProgress
  @Environment(\.clientControlId) private var clientControlId
  @Environment(\.usesSlimComposer) private var usesSlimComposer
  @State private var editorHeight: CGFloat = ChatInputEditor.singleLineHeight
  @State private var selection = NSRange(location: 0, length: 0)
  @State private var slashSelection = 0
  @State private var promptHistory: ComposerPromptHistory?
  @State private var isSlashMenuDismissed = false
  @State private var slashMenuContentHeight: CGFloat = 0
  @State private var didStartResolvingQuestion = false
  @State private var didAcceptSubmission = false
  @State private var isPickingFiles = false
  @State private var isPickingPhotos = false
  @State private var sendSource = ComposerSendSource()

  private static let slashMenuMaxHeight: CGFloat = 220

  private var paletteHeight: CGFloat {
    if isLoadingSlashCommands, slashMenuContentHeight == 0 { return 40 }
    return min(slashMenuContentHeight, Self.slashMenuMaxHeight)
  }

  init(
    controller: SessionController,
    onTextViewReady: ((SubmittingTextView) -> Void)? = nil,
    focus: TerminalFocusController? = nil,
    focusChatId: UUID? = nil,
    glassNamespace: Namespace.ID? = nil
  ) {
    self.controller = controller
    self.onTextViewReady = onTextViewReady
    self.focus = focus
    self.focusChatId = focusChatId
    self.glassNamespace = glassNamespace
  }

  var body: some View {
    ZStack {
      if let question = controller.composerQuestion {
        ComposerQuestionPicker(
          controller: controller,
          request: question,
          didStartResolving: $didStartResolvingQuestion,
          focus: focus,
          chatId: focusChatId
        )
        .transition(Motion.unfold(reduceMotion: reduceMotion, anchor: .bottom))
      } else if isSlimLayout {
        slimContent
      } else {
        standardContent
          .transition(Motion.unfold(reduceMotion: reduceMotion, anchor: .bottom))
      }
    }
    .modifier(ComposerCardChrome(isEnabled: !isSlimLayout, shape: cardStyle.shape, namespace: glassNamespace))
    .overlay(alignment: .top) {
      ZStack(alignment: .top) {
        if controller.composerQuestion == nil, showsSlashCommandPopup {
          ComposerSlashCommandPopup(
            isLoading: isLoadingSlashCommands,
            matches: visibleSlashMatches,
            selectedIndex: slashSelection,
            height: paletteHeight,
            onContentHeightChange: { slashMenuContentHeight = $0 },
            onSelect: acceptSlashCommand
          )
          .transition(.opacity)
        }
      }
      .offset(y: -(paletteHeight + ComposerGlassStyle.clusterSpacing))
      .animation(
        Motion.quick(reduceMotion: reduceMotion),
        value: !showsSlashCommandPopup
      )
    }
    .overlay {
      if controller.composerQuestion != nil, isQuestionResolving {
        ZStack {
          cardStyle.shape
            .fill(Color.windowBackgroundColor.opacity(0.72))
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Submitting response…")
              .font(.callout.weight(.medium))
          }
          .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Submitting response")
      }
    }
    .animation(
      Motion.quick(reduceMotion: reduceMotion),
      value: controller.composerQuestion?.questionId
    )
    .fileImporter(
      isPresented: $isPickingFiles,
      allowedContentTypes: [.item],
      allowsMultipleSelection: true
    ) { result in
      guard case let .success(urls) = result else { return }
      controller.attachments.attachFileURLs(urls)
    }
    .modifier(ComposerPhotosPicker(isPresented: $isPickingPhotos, controller: controller))
    .onChange(of: controller.submitRequest) { _, _ in
      sendDraft(delivery: .steer)
    }
    .onChange(of: controller.composerQuestion?.questionId) { _, _ in
      didStartResolvingQuestion = false
    }
    .onChange(of: slashToken) { oldToken, newToken in
      slashSelection = 0
      isSlashMenuDismissed = false
      if oldToken == nil, newToken != nil {
        controller.refreshCodevisorSkills()
      }
    }
  }
}

private extension ComposerCard {
  private var isSlimLayout: Bool {
    usesSlimComposer && controller.composerQuestion == nil && !controller.isEditingQueuedPrompt
      && !controller.isGoalEditing
  }

  private var slimContent: some View {
    ComposerSlimBar(
      field: editorStack, glassNamespace: glassNamespace, onAttachPhotos: pickPhotos, onAttachFiles: pickFiles)
  }

  private var standardContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      editorStack

      HStack(spacing: 10) {
        controlsRow
      }
      .font(.callout)
    }
  }

  private var editorStack: some View {
    VStack(alignment: .leading, spacing: 4) {
      if controller.isGoalEditing {
        ComposerModeLabel(systemImage: "target", title: "Edit goal")
      }
      if !controller.composerAttachments.isEmpty {
        ComposerAttachmentRow(controller: controller)
      }

      ZStack(alignment: .topLeading) {
        ChatInputEditor(
          text: $controller.composerText,
          calculatedHeight: $editorHeight,
          selection: $selection,
          topBleed: editorTopBleed,
          onSubmit: submitOrAcceptSlash,
          onQueueSubmit: submitToQueue,
          onKeyCommand: handleKeyCommand,
          onPasteAttachments: handlePastedAttachments,
          onTextViewReady: { textView in
            sendSource.textView = textView
            onTextViewReady?(textView)
          }
        )
        .frame(height: editorHeight + editorTopBleed)
        .writingToolsAffordanceVisibility(.hidden)
        .onChange(of: controller.editingQueuedPromptID) { _, _ in
          selection = NSRange(location: (controller.composerText as NSString).length, length: 0)
        }
        .disabled(
          isAcceptingSubmission
            || controller.isResolvingQuestion
            || isAppUpdateInProgress
        )

        if controller.composerText.isEmpty, !isAcceptingSubmission {
          Text(controller.composerPlaceholder)
            .foregroundStyle(.tertiary)
            .padding(.top, 6 + editorTopBleed)
            .allowsHitTesting(false)
        }
      }
      .padding(.top, -editorTopBleed)
    }
  }

  @ViewBuilder
  private var controlsRow: some View {
    if controller.isGoalEditing {
      Text("esc to cancel")
        .font(.caption2)
        .foregroundStyle(.tertiary)
      Spacer(minLength: 0)
      HStack(spacing: 4) {
        goalEditBackButton
        sendButton
      }
    } else if controller.isEditingQueuedPrompt {
      attachButton
      ComposerQueueEditControls(
        canSave: hasComposerDraft && !isAcceptingSubmission,
        onCancel: controller.cancelEditingQueuedPrompt,
        onSave: saveQueueEdit
      )
    } else {
      attachButton
      ModelConfigMenu(controller: controller)
      if controller.hasPlanMode, controller.isPlanModeOn {
        ModeChip(
          label: "Plan",
          systemImage: "map",
          isRemoveDisabled: controller.isPlanModeUpdatePending
        ) {
          Task { await controller.togglePlanMode() }
        }
      }
      if controller.canEditGoal, controller.isGoalComposerArmed {
        ModeChip(label: "Goal", systemImage: "target") {
          withAnimation(.snappy(duration: 0.15)) { controller.exitGoalComposer() }
        }
      }
      Spacer(minLength: 0)
      HStack(spacing: 4) {
        if controller.canStop { stopButton }
        if showsSendButton { sendButton }
      }
    }
  }

  private var editorTopBleed: CGFloat {
    controller.isGoalEditing || !controller.composerAttachments.isEmpty || isSlimLayout
      ? 0
      : ComposerCardStyle.contentPadding
  }

  private var isQuestionResolving: Bool {
    didStartResolvingQuestion || controller.isResolvingQuestion
  }

  private var goalEditBackButton: some View {
    ComposerNavigationButton(
      systemImage: "arrow.left",
      help: "Back — keep the current goal (esc)",
      accessibilityLabel: "Back"
    ) {
      withAnimation(.snappy(duration: 0.15)) { controller.exitGoalComposer() }
    }
    .accessibilityHint("Keep the current goal. Keyboard shortcut: Escape")
  }

  private func saveQueueEdit() {
    guard !isAcceptingSubmission, hasComposerDraft else { return }
    didAcceptSubmission = true
    Task {
      await controller.saveEditedQueuedPrompt()
      didAcceptSubmission = false
    }
  }

  private var attachButton: some View {
    ComposerAttachButton(onPhotos: pickPhotos, onFiles: pickFiles)
  }

  private func pickPhotos() {
    isPickingPhotos = true
  }

  private func pickFiles() {
    isPickingFiles = true
  }

  private var hasComposerDraft: Bool {
    !controller.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !controller.composerAttachments.isEmpty
  }

  private func handlePastedAttachments(_ pasted: [PastedAttachment]) -> Bool {
    guard !pasted.isEmpty else { return false }
    for item in pasted {
      switch item {
      case let .fileURL(url):
        controller.attachments.attachFileURLs([url])
      case let .image(data, suggestedName):
        controller.attachments.attachImageData(data, suggestedName: suggestedName)
      }
    }
    return true
  }

  private var showsSendButton: Bool {
    !controller.canStop || hasComposerDraft
  }

  private var stopButton: some View {
    ComposerStopButton(isCancelling: controller.isCancelling) {
      Task { await controller.stop() }
    }
  }

  @ViewBuilder
  private var sendButton: some View {
    if isAcceptingSubmission || controller.isResolvingQuestion {
      ProgressView()
        .controlSize(.small)
        .frame(width: 26, height: 26)
        .background(Circle().fill(Color.secondary.opacity(0.16)))
        .help(controller.isResolvingQuestion ? "Submitting response…" : "Sending…")
    } else {
      ComposerSubmitButton(
        isEnabled: sendAvailability.isEnabled, help: sendAvailability.help, accessibilityLabel: "Send"
      ) {
        submitOrAcceptSlash()
      }
    }
  }

  private var sendAvailability: ComposerSendAvailability {
    ComposerSendAvailability(
      controller: controller, hasDraft: hasComposerDraft, hasSlashMatches: !visibleSlashMatches.isEmpty,
      isAppUpdateInProgress: isAppUpdateInProgress)
  }

  private var slashToken: ComposerSlashToken? {
    guard controller.offersSlashCommands else { return nil }
    return ComposerSlashToken(in: controller.composerText, selection: selection)
  }

  private var localSlashCommands: [ComposerSlashItem] {
    var items: [ComposerSlashItem] = []
    if controller.hasPlanMode {
      items.append(
        ComposerSlashItem(name: "plan", description: "Toggle plan mode") {
          Task { await controller.togglePlanMode() }
        }
      )
    }
    if controller.canEditGoal {
      items.append(
        ComposerSlashItem(name: "goal", description: "Toggle goal mode") {
          withAnimation(.snappy(duration: 0.15)) { controller.toggleGoalComposer() }
        }
      )
    }
    if controller.supportsCompaction {
      items.append(
        ComposerSlashItem(name: "compact", description: "Summarize the chat to free up context") {
          controller.compact()
        }
      )
    }
    return items
  }

  private var slashMatches: [ComposerSlashItem] {
    guard let token = slashToken else { return [] }
    let skills = ComposerSkillCatalog.matches(controller.composerSkills, query: token.query)
      .map(ComposerSlashItem.init(skill:))
    guard token.trigger == .slash else { return skills }
    let commands = localSlashCommands
    let query = token.query
    let exact = commands.filter { $0.name.lowercased() == query }
    let prefixed = commands.filter { command in
      command.name.lowercased().hasPrefix(query) && !exact.contains(where: { $0.id == command.id })
    }
    return exact + prefixed + skills
  }

  private var visibleSlashMatches: [ComposerSlashItem] {
    isSlashMenuDismissed ? [] : slashMatches
  }

  private var isLoadingSlashCommands: Bool {
    slashToken != nil && controller.isConnectingToHarness && !isSlashMenuDismissed
  }

  private var showsSlashCommandPopup: Bool {
    isLoadingSlashCommands || !visibleSlashMatches.isEmpty
  }

  private var isAcceptingSubmission: Bool {
    didAcceptSubmission
  }

  private func submitOrAcceptSlash() {
    guard !isAcceptingSubmission, !controller.isResolvingQuestion else { return }
    if isLoadingSlashCommands { return }
    if let command = selectedSlashCommand {
      acceptSlashCommand(command)
    } else if controller.isEditingQueuedPrompt {
      saveQueueEdit()
    } else if controller.isGoalComposerArmed {
      let hasGoal = !controller.composerText
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty
      guard hasGoal,
        controller.isServerReady,
        controller.isConnected || controller.selectedHarness != nil,
        !controller.isConnecting,
        !controller.isConnectingToHarness,
        !controller.isPausedForUpdate,
        !isAppUpdateInProgress
      else { return }
      didAcceptSubmission = true
      Task {
        await controller.submitGoalFromComposer()
        didAcceptSubmission = false
      }
    } else {
      sendDraft(delivery: .steer)
    }
  }

  private func submitToQueue() -> Bool {
    guard controller.canQueueMessages, hasComposerDraft, !controller.isGoalComposerArmed,
      !controller.isEditingQueuedPrompt,
      selectedSlashCommand == nil, !isAcceptingSubmission
    else { return false }
    sendDraft(delivery: .queue)
    return true
  }

  private func sendDraft(delivery: ServerPromptDelivery) {
    guard controller.canSend, !isAppUpdateInProgress else { return }
    if controller.interceptsSend(delivery) { return }
    if !reduceMotion, !controller.sendLandsInQueue(delivery) {
      sendSource.stage(controller: controller)
    }
    controller.promptClientId = clientControlId?.uuidString.lowercased()
    Task { await controller.send(delivery: delivery) }
  }

  private var selectedSlashCommand: ComposerSlashItem? {
    let matches = visibleSlashMatches
    guard !matches.isEmpty else { return nil }
    return matches[min(slashSelection, matches.count - 1)]
  }

  private func acceptSlashCommand(_ command: ComposerSlashItem) {
    guard let tokenRange = slashToken?.range else { return }
    let replacement = command.action == nil ? "\(command.title) " : ""
    if let textView = sendSource.textView {
      textView.replaceAsUndoableEdit(tokenRange, with: replacement)
    } else {
      controller.composerText = (controller.composerText as NSString)
        .replacingCharacters(in: tokenRange, with: replacement)
    }
    selection = NSRange(
      location: tokenRange.location + (replacement as NSString).length,
      length: 0
    )
    command.action?()
    slashSelection = 0
  }

  private func handleKeyCommand(_ command: ComposerKeyCommand) -> Bool {
    if handleSlashMenuKeyCommand(command) {
      return true
    }
    if controller.isEditingQueuedPrompt, command == .dismissSelection {
      controller.cancelEditingQueuedPrompt()
      return true
    }
    if controller.isGoalComposerArmed, command == .dismissSelection {
      controller.exitGoalComposer()
      return true
    }
    guard command == .recallPreviousPrompt || command == .recallNextPrompt else { return false }
    let older = command == .recallPreviousPrompt
    guard let caret = controller.recallPrompt(&promptHistory, older: older) else {
      return older && promptHistory != nil
    }
    selection = caret
    return true
  }

  private func handleSlashMenuKeyCommand(_ command: ComposerKeyCommand) -> Bool {
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
    case .recallPreviousPrompt, .recallNextPrompt:
      return false
    }
  }
}
