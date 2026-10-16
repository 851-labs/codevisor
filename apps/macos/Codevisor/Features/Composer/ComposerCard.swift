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
  @State private var editorHeight: CGFloat = ChatInputEditor.singleLineHeight
  @State private var selection = NSRange(location: 0, length: 0)
  @State private var slashSelection = 0
  @State private var promptHistory: ComposerPromptHistory?
  @State private var isSlashMenuDismissed = false
  @State private var slashMenuContentHeight: CGFloat = 0
  @State private var isStopButtonHovered = false
  @State private var didStartResolvingQuestion = false
  @State private var didAcceptSubmission = false
  @State private var isPickingFiles = false
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
      if let question = controller.activeQuestion {
        QuestionPickerContent(
          controller: controller,
          request: question,
          didStartResolving: $didStartResolvingQuestion,
          focus: focus,
          chatId: focusChatId
        )
        .transition(Motion.unfold(reduceMotion: reduceMotion, anchor: .bottom))
      } else {
        standardContent
          .transition(Motion.unfold(reduceMotion: reduceMotion, anchor: .bottom))
      }
    }
    .padding(ComposerCardStyle.contentPadding)
    .composerGlassSurface(
      shape: cardStyle.shape,
      id: .composer,
      in: glassNamespace
    )
    .overlay(alignment: .top) {
      ZStack(alignment: .top) {
        if controller.activeQuestion == nil, showsSlashCommandPopup {
          ComposerSlashCommandPopup(
            isLoading: isLoadingSlashCommands,
            matches: visibleSlashMatches,
            selectedIndex: slashSelection,
            height: paletteHeight,
            onContentHeightChange: { slashMenuContentHeight = $0 },
            onSelect: acceptSlashCommand
          )
          .transition(Motion.unfold(reduceMotion: reduceMotion, anchor: .bottom))
        }
      }
      .offset(y: -(paletteHeight + ComposerGlassStyle.clusterSpacing))
      .animation(
        Motion.quick(reduceMotion: reduceMotion),
        value: !showsSlashCommandPopup
      )
    }
    .overlay {
      if controller.activeQuestion != nil, isQuestionResolving {
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
      value: controller.activeQuestion?.questionId
    )
    .fileImporter(
      isPresented: $isPickingFiles,
      allowedContentTypes: [.item],
      allowsMultipleSelection: true
    ) { result in
      guard case let .success(urls) = result else { return }
      controller.attachments.attachFileURLs(urls)
    }
    .onChange(of: controller.activeQuestion?.questionId) { _, _ in
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
  private var standardContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        if controller.isGoalEditing {
          HStack(spacing: 6) {
            Image(systemName: "target")
              .font(.caption)
            Text("Edit goal")
              .font(.caption.weight(.semibold))
          }
          .foregroundStyle(.secondary)
        }
        if !controller.composerAttachments.isEmpty {
          ComposerAttachmentRow(controller: controller)
        }

        ZStack(alignment: .topLeading) {
          ChatInputEditor(
            text: $controller.composerText,
            calculatedHeight: $editorHeight,
            selection: $selection,
            onSubmit: submitOrAcceptSlash,
            onKeyCommand: handleKeyCommand,
            onPasteAttachments: handlePastedAttachments,
            onTextViewReady: { textView in
              sendSource.textView = textView
              onTextViewReady?(textView)
            }
          )
          .frame(height: editorHeight)
          .writingToolsAffordanceVisibility(.hidden)
          .disabled(
            isAcceptingSubmission
              || controller.isResolvingQuestion
              || isAppUpdateInProgress
          )

          if controller.composerText.isEmpty, !isAcceptingSubmission {
            Text("Do something")
              .foregroundStyle(.tertiary)
              .padding(.top, 6)
              .allowsHitTesting(false)
          }
        }
      }

      HStack(spacing: 10) {
        if controller.isGoalEditing {
          Text("esc to cancel")
            .font(.caption2)
            .foregroundStyle(.tertiary)
          Spacer(minLength: 0)
          HStack(spacing: 4) {
            goalEditBackButton
            sendButton
          }
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
            if controller.isSending, !hasComposerDraft {
              stopButton
            } else {
              stopButton
              sendButton
            }
          }
        }
      }
      .font(.callout)
    }
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

  private var attachButton: some View {
    Button(action: pickFiles) {
      Image(systemName: "paperclip")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
    }
    .buttonStyle(HoverIconButtonStyle())
    .help("Attach files")
    .accessibilityLabel("Attach files")
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

  @ViewBuilder
  private var stopButton: some View {
    if controller.isSending {
      if controller.isCancelling {
        ProgressView()
          .controlSize(.small)
          .frame(width: 26, height: 26)
          .help("Stopping…")
      } else {
        Button(action: stop) {
          Image(systemName: "stop.fill")
            .font(.system(size: 10, weight: .bold))
            .frame(width: 26, height: 26)
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
        .accessibilityLabel("Stop")
      }
    }
  }

  private func stop() {
    Task { await controller.stop() }
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
      let hasSubmittableContent =
        controller.isGoalComposerArmed
        ? !controller.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        : hasComposerDraft || !visibleSlashMatches.isEmpty
      let isBlockedByCapabilities =
        hasSubmittableContent
        && controller.isConnectingToHarness
      let isEnabled =
        !isAppUpdateInProgress
        && controller.isServerReady
        && (controller.isGoalComposerArmed
          ? hasSubmittableContent
            && (controller.isConnected || controller.selectedHarness != nil)
            && !controller.isConnecting
            && !controller.isConnectingToHarness
            && !controller.requiresModelSelection
          : !controller.isConnectingToHarness
            && (controller.canSend || !visibleSlashMatches.isEmpty))
      ComposerSubmitButton(
        isEnabled: isEnabled,
        help: isAppUpdateInProgress
          ? "Updating… you can send once the update finishes."
          : isBlockedByCapabilities
            ? "Connecting to harness…"
            : controller.isConnecting
              ? "Connecting… you can send once the agent is ready."
              : controller.requiresModelSelection ? "Select a model" : "Send (↩)",
        accessibilityLabel: "Send"
      ) {
        submitOrAcceptSlash()
      }
    }
  }

  private var slashToken: ComposerSlashToken? {
    ComposerSlashToken(in: controller.composerText, selection: selection)
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
    didAcceptSubmission || controller.isSubmitting
  }

  private func submitOrAcceptSlash() {
    guard !isAcceptingSubmission, !controller.isResolvingQuestion else { return }
    if isLoadingSlashCommands { return }
    if let command = selectedSlashCommand {
      acceptSlashCommand(command)
    } else if controller.isGoalComposerArmed {
      let hasGoal = !controller.composerText
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty
      guard hasGoal,
        controller.isServerReady,
        controller.isConnected || controller.selectedHarness != nil,
        !controller.isConnecting,
        !controller.isConnectingToHarness,
        !isAppUpdateInProgress
      else { return }
      didAcceptSubmission = true
      Task {
        await controller.submitGoalFromComposer()
        didAcceptSubmission = false
      }
    } else {
      guard controller.canSend, !isAppUpdateInProgress else { return }
      didAcceptSubmission = true
      if !reduceMotion, !controller.isSending {
        sendSource.stage(controller: controller)
      }
      controller.promptClientId = clientControlId?.uuidString.lowercased()
      Task {
        await controller.send()
        didAcceptSubmission = false
      }
    }
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
