import ACPKit
import AppKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI

struct AssistantTurnView: View {
  let turn: AssistantTurn
  let turnID: UUID
  let isWaitingOnUser: Bool
  let waitingOnBackgroundTask: String?
  let goalActivity: GoalActivity?
  let presentation: AssistantTurnPresentation
  private let initiallyExpanded: Bool?
  @Environment(\.transcriptDisclosure) private var disclosureStore
  @Environment(\.transcriptController) private var transcriptController
  @Environment(\.transcriptPerformAnchoredDisclosureChange) private var performAnchoredDisclosureChange
  @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateRowMeasurement
  @Environment(\.openSettings) private var openSettings
  @Environment(\.quickLook) private var quickLook
  @Environment(\.openFileDocument) private var openFileDocument
  @Environment(\.attachmentImages) private var attachmentImages
  @Environment(\.streamingTextAnimationVisibility) private var textAnimationVisibility
  @State private var textAnimationPresentation = StreamingTextAnimationPresentation()
  @State private var hasAutoCollapsed = false

  init(
    turn: AssistantTurn,
    turnID: UUID = UUID(),
    initiallyExpanded: Bool? = nil,
    isWaitingOnUser: Bool = false,
    waitingOnBackgroundTask: String? = nil,
    goalActivity: GoalActivity? = nil,
    presentation: AssistantTurnPresentation = .complete
  ) {
    self.turn = turn
    self.turnID = turnID
    self.initiallyExpanded = initiallyExpanded
    self.isWaitingOnUser = isWaitingOnUser
    self.waitingOnBackgroundTask = waitingOnBackgroundTask
    self.goalActivity = goalActivity
    self.presentation = presentation
    _hasAutoCollapsed = State(initialValue: turn.isGenerating && turn.finalTextIsAsserted)
  }

  private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }

  private var sectionKeys: [TranscriptDisclosureStore.Key] {
    switch presentation {
    case .complete: [.turn(turnID), .turnImplementation(turnID)]
    case .planning: [.turn(turnID)]
    case .result: [.turnImplementation(turnID)]
    case .completePrelude: [.turn(turnID), .turnImplementation(turnID)]
    case .resultPrelude: [.turnImplementation(turnID)]
    case .response, .activity, .epilogue: []
    }
  }

  private func isExpanded(_ key: TranscriptDisclosureStore.Key) -> Bool {
    let settled = !turn.isGenerating || turn.finalTextIsAsserted
    return store.isExpanded(key, default: initiallyExpanded ?? !settled)
  }

  private func showsWorkedSection(
    _ kind: TranscriptWorkedSectionKind, items: [WorkedItem]
  ) -> Bool {
    turn.defersWorkedSection(kind) || !items.isEmpty
  }

  var body: some View {
    let animationEnabled = prepareTextAnimationPresentation()
    let beforePlan = turn.workedItemsBeforePlan
    let afterPlan = turn.workedItemsAfterPlan
    let finalText = turn.finalText
    let activity = AssistantTurnActivity.resolve(
      turn: turn, isWaitingOnUser: isWaitingOnUser,
      sessionActivity: transcriptController?.transcriptActivityOverride,
      backgroundTask: waitingOnBackgroundTask, goalActivity: goalActivity)
    VStack(alignment: .leading, spacing: 14) {
      if presentation.showsPlanning, showsWorkedSection(.planning, items: beforePlan) {
        workedSection(items: beforePlan, kind: .planning)
      }

      if presentation.showsPlanDocument,
        let planDocument = turn.planDocument, !planDocument.isEmpty
      {
        PlanDocumentView(markdown: planDocument)
      }

      if presentation.showsResultWork, showsWorkedSection(.implementation, items: afterPlan) {
        workedSection(items: afterPlan, kind: .implementation)
      }

      if presentation.showsActivity, activity.map({ !$0.followsResponse }) ?? turn.reservesActivitySlot {
        AssistantTurnActivitySlot(activity, turn: turn)
      }
      if presentation.showsResponse {
        ForEach(turn.generatedImageActivity) { call in
          ImageGenerationActivityView(call: call)
        }
      }

      if presentation.showsResponse,
        let final = finalText, case let .text(entryID, markdown) = final
      {
        assistantResponse(
          entryID: entryID,
          markdown: markdown,
          animationEnabled: animationEnabled
        )
      }

      if presentation.showsResponse, finalText == nil, !turn.attachments.isEmpty {
        assistantResponse(
          entryID: "attachments",
          markdown: "",
          animationEnabled: animationEnabled
        )
      }

      if presentation.showsEpilogue, let activity, activity.followsResponse {
        AssistantTurnActivityView(activity)
      }

      if presentation.showsEpilogue,
        !turn.isGenerating, let stopDetail = turn.stopDetail
      {
        turnErrorRow(stopDetail)
      }
    }
    .markdownLinkHandler(openMarkdownLink)
    .markdownImageActions(
      TranscriptMarkdownImageOpener.actions(
        quickLook: quickLook, attachmentImages: attachmentImages, openDocument: openFileDocument)
    )
    .frame(maxWidth: .infinity, alignment: .leading)
    .onChange(of: turn.isGenerating) { _, generating in
      if generating {
        if !hasAutoCollapsed {
          for key in sectionKeys { store.setExpanded(key, true) }
          invalidateRowMeasurement?()
        }
        return
      }
      autoCollapse()
    }
    .onChange(of: turn.finalTextIsAsserted) { _, asserted in
      guard turn.isGenerating else { return }
      if asserted {
        autoCollapse()
      } else {
        reopenForActiveWork()
      }
    }
  }

  @ViewBuilder
  private func assistantResponse(
    entryID: String,
    markdown: String,
    animationEnabled: Bool
  ) -> some View {
    StreamingAssistantResponseView(
      turnID: turnID,
      entryID: entryID,
      markdown: markdown,
      attachments: turn.attachments,
      isGenerating: turn.isGenerating,
      animationPresentation: textAnimationPresentation,
      animationEnabled: animationEnabled
    ) { file, label in
      TranscriptInlineFile(file: file, label: label) {
        AttachmentThumbnailView(file: file)
      }
    }
  }

  private func prepareTextAnimationPresentation() -> Bool {
    textAnimationPresentation.establishBaseline(
      settling: turn,
      turnID: turnID
    )
    if let textAnimationVisibility {
      textAnimationPresentation.updateVisibility(
        generation: textAnimationVisibility.generation,
        isVisible: textAnimationVisibility.isVisible
      ) {
        TranscriptStreamingTextIdentity.settledStreamIDs(
          turn: turn,
          turnID: turnID
        )
      }
    }
    if turn.hasHydratedWorkedDetails {
      textAnimationPresentation.settleRestoredStreams(
        {
          TranscriptStreamingTextIdentity.settledStreamIDs(
            turn: turn,
            turnID: turnID
          )
        },
        restorationID: turn.detailRevision
      )
    }
    return textAnimationPresentation.animationsEnabled
  }

  private func openMarkdownLink(_ url: URL) -> Bool {
    TranscriptMarkdownLinkOpener.open(
      url, quickLook: quickLook, attachmentImages: attachmentImages,
      openDocument: openFileDocument
    )
  }

  @ViewBuilder
  private func turnErrorRow(_ message: String) -> some View {
    if turn.stopKind == "usageLimit" {
      UsageLimitNotice(
        autoResume: turn.autoResume,
        inBotConversation: transcriptController?.presentsBotConversation == true,
        switchAccount: openHarnessAccountSettings,
        cancelAutoResume: { Task { await transcriptController?.cancelAutoResume() } }
      )
    } else if turn.stopKind == "authRequired"
      || (transcriptController?.errorRequiresHarnessAuthentication == true
        && transcriptController?.errorMessage == message)
    {
      ChatErrorRow(
        message,
        actionTitle: "Sign In",
        action: openHarnessAccountSettings
      )
    } else if let failure = turn.harnessFailure {
      HarnessFailureNotice(
        failure: failure,
        detail: message,
        harnessName: transcriptController?.activeHarnessName,
        inBotConversation: transcriptController?.presentsBotConversation == true,
        retry: retryAction,
        switchAccount: openHarnessAccountSettings
      )
    } else if let transcriptController,
      transcriptController.canRetryTurn(turnID)
    {
      ChatErrorRow(
        message,
        actionTitle: "Retry response",
        action: { Task { await transcriptController.retryTurn(turnID) } }
      )
    } else {
      ChatErrorRow(message)
    }
  }

  private var retryAction: (() -> Void)? {
    guard let transcriptController, transcriptController.canRetryTurn(turnID) else { return nil }
    return { Task { await transcriptController.retryTurn(turnID) } }
  }

  private func openHarnessAccountSettings() {
    guard let transcriptController,
      let harnessId = transcriptController.activeHarnessId
    else {
      SettingsRouter.shared.showHarnesses()
      openSettings()
      return
    }
    SettingsRouter.shared.showHarnessAccounts(
      machineId: transcriptController.project.serverId,
      harnessId: harnessId
    )
    openSettings()
  }

  private func autoCollapse() {
    guard !hasAutoCollapsed else { return }
    hasAutoCollapsed = true
    for key in sectionKeys { store.setExpanded(key, false) }
    invalidateRowMeasurement?()
  }

  private func reopenForActiveWork() {
    hasAutoCollapsed = false
    for key in sectionKeys { store.setExpanded(key, true) }
    invalidateRowMeasurement?()
  }

  private func workedSection(
    items: [WorkedItem],
    kind: TranscriptWorkedSectionKind
  ) -> some View {
    let key: TranscriptDisclosureStore.Key =
      kind == .planning ? .turn(turnID) : .turnImplementation(turnID)
    let expanded = isExpanded(key)
    let deferredDetailItemID =
      turn.defersWorkedSection(kind)
      ? turn.deferredDetailItemId
      : nil
    return VStack(alignment: .leading, spacing: 12) {
      if turn.isWorkedSectionLive(kind), !hasAutoCollapsed {
        workedHeader(
          label: sectionLabel(kind),
          showsChevron: false,
          expanded: expanded,
          deferredDetailItemID: nil
        )
      } else {
        Button {
          let change = {
            if expanded {
              store.setExpanded(key, false)
            } else {
              store.setExpanded(key, true)
            }
            invalidateRowMeasurement?()
          }
          performAnchoredDisclosureChange?(change) ?? change()
        } label: {
          workedHeader(
            label: sectionLabel(kind),
            showsChevron: true,
            expanded: expanded,
            deferredDetailItemID: deferredDetailItemID
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(TranscriptWorkedSectionButtonStyle())
      }

      TranscriptDisclosureContentReveal(
        isExpanded: expanded && !items.isEmpty
      ) {
        VStack(alignment: .leading, spacing: 12) {
          TranscriptItemsView(
            items: items,
            turnID: turnID,
            isTurnActive: turn.isGenerating,
            animationPresentation: textAnimationPresentation,
            animationEnabled: textAnimationPresentation.animationsEnabled
          )
        }
      }
    }
  }

  private func workedHeader(
    label: some View,
    showsChevron: Bool,
    expanded: Bool,
    deferredDetailItemID: String?
  ) -> some View {
    HStack(spacing: 6) {
      label
      if showsChevron {
        TranscriptWorkedDisclosureIndicator(
          expanded: expanded,
          deferredDetailItemID: deferredDetailItemID
        )
      }
      Spacer(minLength: 0)
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .transaction { transaction in
      transaction.animation = nil
    }
  }

  @ViewBuilder
  private func sectionLabel(_ kind: TranscriptWorkedSectionKind) -> some View {
    if turn.workedSectionTicks(kind) {
      TimelineView(.periodic(from: turn.workedSectionStart(kind) ?? Date(), by: 1)) { context in
        Text(turn.workedSectionTitle(kind, now: context.date))
      }
    } else {
      Text(turn.workedSectionTitle(kind, now: Date()))
    }
  }
}

#Preview("Worked-for expanded") {
  ScrollView {
    if case let .assistant(message) = SampleData.conversation[1] {
      AssistantTurnView(turn: message.turn, initiallyExpanded: true).padding()
    }
  }
  .frame(width: 600, height: 640)
}

#Preview("Thinking") {
  if case let .assistant(message) = SampleData.streamingConversation[1] {
    AssistantTurnView(turn: message.turn).padding().frame(width: 580)
  }
}
