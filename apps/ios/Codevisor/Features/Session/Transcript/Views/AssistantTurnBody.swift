// swiftlint:disable type_body_length

import ACPKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI
import TranscriptKit

struct AssistantTurnBody: View {
  @Environment(\.openFileDocument) private var openFileDocument
  @Environment(\.transcriptDisclosure) private var disclosureStore
  @Environment(\.transcriptController) private var transcriptController
  @Environment(\.runningSubagentRunToolCallIds) private var runningSubagentRuns
  @Environment(\.transcriptPerformAnchoredDisclosureChange)
  private var performAnchoredDisclosureChange
  @Environment(\.transcriptInvalidateRowMeasurement)
  private var invalidateRowMeasurement
  @Environment(\.attachmentImages) private var attachmentImages
  @Environment(\.quickLook) private var quickLook
  @Environment(\.streamingTextAnimationVisibility) private var textAnimationVisibility
  @State private var textAnimationPresentation = StreamingTextAnimationPresentation()
  @State private var hasAutoCollapsed: Bool
  let turn: AssistantTurn
  let turnId: UUID
  let isWaitingOnUser: Bool
  let waitingOnBackgroundTask: String?
  let goalActivity: GoalActivity?
  let presentation: AssistantTurnPresentation

  init(
    turn: AssistantTurn,
    turnId: UUID,
    isWaitingOnUser: Bool = false,
    waitingOnBackgroundTask: String? = nil,
    goalActivity: GoalActivity? = nil,
    presentation: AssistantTurnPresentation = .complete
  ) {
    self.turn = turn
    self.turnId = turnId
    self.isWaitingOnUser = isWaitingOnUser
    self.waitingOnBackgroundTask = waitingOnBackgroundTask
    self.goalActivity = goalActivity
    self.presentation = presentation
    _hasAutoCollapsed = State(initialValue: turn.isGenerating && turn.finalTextIsAsserted)
  }

  private var store: TranscriptDisclosureStore { disclosureStore ?? .previews }
  private var isGenerating: Bool { turn.isGenerating }

  private var sectionKeys: [TranscriptDisclosureStore.Key] {
    switch presentation {
    case .complete: [.turn(turnId), .turnImplementation(turnId)]
    case .planning: [.turn(turnId)]
    case .result: [.turnImplementation(turnId)]
    case .completePrelude: [.turn(turnId), .turnImplementation(turnId)]
    case .resultPrelude: [.turnImplementation(turnId)]
    case .response, .activity, .epilogue: []
    }
  }

  private func isExpanded(_ key: TranscriptDisclosureStore.Key) -> Bool {
    store.isExpanded(key, default: !settled)
  }

  private var hasRunningSubagent: Bool {
    turn.startedRunningSubagent(runningSubagentRuns)
  }

  private var settled: Bool {
    (!isGenerating || turn.finalTextIsAsserted) && !hasRunningSubagent
  }

  var body: some View {
    let animationEnabled = prepareTextAnimationPresentation()
    let finalText = turn.finalText
    let activity = AssistantTurnActivity.resolve(
      turn: turn, isWaitingOnUser: isWaitingOnUser,
      sessionActivity: transcriptController?.transcriptActivityOverride,
      backgroundTask: waitingOnBackgroundTask, goalActivity: goalActivity)
    VStack(alignment: .leading, spacing: 14) {
      if presentation.showsPlanning {
        workedSection(
          items: turn.workedItemsBeforePlan,
          kind: .planning
        )
      }
      if presentation.showsPlanDocument, let planDocument = turn.planDocument {
        PlanDocumentView(markdown: planDocument)
      }
      if presentation.showsResultWork {
        workedSection(
          items: turn.workedItemsAfterPlan,
          kind: .implementation
        )
      }
      if presentation.showsActivity, activity.map({ !$0.followsResponse }) ?? turn.reservesActivitySlot {
        AssistantTurnActivitySlot(activity, turn: turn)
      }
      if presentation.showsResponse {
        ForEach(turn.generatedImageActivity) { call in
          ImageGenerationActivityView(call: call)
        }
        if case let .text(entryID, markdown) = finalText {
          assistantResponse(
            entryID: entryID,
            markdown: markdown,
            animationEnabled: animationEnabled
          )
        }
        if finalText == nil, !turn.attachments.isEmpty {
          assistantResponse(
            entryID: "attachments",
            markdown: "",
            animationEnabled: animationEnabled
          )
        }
      }
      if presentation.showsEpilogue {
        if let activity, activity.followsResponse {
          AssistantTurnActivityView(activity)
        }
        if !isGenerating, let stopDetail = turn.stopDetail {
          turnErrorRow(stopDetail)
        }
      }
    }
    .markdownLinkHandler(openMarkdownLink)
    .markdownImageActions(imageActions)
    .frame(maxWidth: .infinity, alignment: .leading)
    .onChange(of: isGenerating) { _, generating in
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
      guard isGenerating else { return }
      if asserted {
        autoCollapse()
      } else {
        reopenForActiveWork()
      }
    }
    .onChange(of: hasRunningSubagent) { _, running in
      if !running, !isGenerating { autoCollapse() }
    }
  }

  @ViewBuilder
  private func assistantResponse(
    entryID: String,
    markdown: String,
    animationEnabled: Bool
  ) -> some View {
    StreamingAssistantResponseView(
      turnID: turnId,
      entryID: entryID,
      markdown: markdown,
      attachments: turn.attachments,
      isGenerating: isGenerating,
      animationPresentation: textAnimationPresentation,
      animationEnabled: animationEnabled
    ) { file, label in
      VStack(alignment: .leading, spacing: 4) {
        AttachmentThumbnailView(file: file, inline: true)
          .accessibilityLabel(label)
        if file.kind != .image {
          Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func prepareTextAnimationPresentation() -> Bool {
    textAnimationPresentation.establishBaseline(
      settling: turn,
      turnID: turnId
    )
    if let textAnimationVisibility {
      textAnimationPresentation.updateVisibility(
        generation: textAnimationVisibility.generation,
        isVisible: textAnimationVisibility.isVisible
      ) {
        TranscriptStreamingTextIdentity.settledStreamIDs(
          turn: turn,
          turnID: turnId
        )
      }
    }
    if turn.hasHydratedWorkedDetails {
      textAnimationPresentation.settleRestoredStreams(
        {
          TranscriptStreamingTextIdentity.settledStreamIDs(
            turn: turn,
            turnID: turnId
          )
        },
        restorationID: turn.detailRevision
      )
    }
    return textAnimationPresentation.animationsEnabled
  }

  @ViewBuilder
  private func turnErrorRow(_ message: String) -> some View {
    if turn.stopKind == "usageLimit" {
      ChatErrorRow(
        message,
        actionTitle: "Switch Account",
        action: { [weak transcriptController] in
          guard let controller = transcriptController,
            let harnessId = controller.activeHarnessId
          else { return }
          HarnessSignInRequest(
            serverId: controller.project.serverId, harnessId: harnessId
          ).post()
        }
      )
    } else if let transcriptController,
      transcriptController.errorRequiresHarnessAuthentication,
      transcriptController.errorMessage == message
    {
      ChatErrorRow(
        message,
        actionTitle: "Sign In",
        action: { [weak transcriptController] in
          guard let controller = transcriptController,
            let harnessId = controller.activeHarnessId
          else { return }
          HarnessSignInRequest(
            serverId: controller.project.serverId, harnessId: harnessId
          ).post()
        }
      )
    } else if let transcriptController,
      transcriptController.canRetryTurn(turnId)
    {
      ChatErrorRow(
        message,
        actionTitle: "Retry response",
        action: { Task { await transcriptController.retryTurn(turnId) } }
      )
    } else {
      ChatErrorRow(message)
    }
  }

  private var imageActions: MarkdownImageActions {
    TranscriptMarkdownImageOpener.actions(
      quickLook: quickLook, attachmentImages: attachmentImages, openDocument: openFileDocument)
  }

  private func openMarkdownLink(_ url: URL) -> Bool {
    TranscriptMarkdownLinkOpener.open(
      url, quickLook: quickLook, attachmentImages: attachmentImages, openDocument: openFileDocument)
  }

  private func autoCollapse() {
    guard !hasAutoCollapsed, !hasRunningSubagent else { return }
    hasAutoCollapsed = true
    for key in sectionKeys { store.setExpanded(key, false) }
    invalidateRowMeasurement?()
  }

  private func reopenForActiveWork() {
    hasAutoCollapsed = false
    for key in sectionKeys { store.setExpanded(key, true) }
    invalidateRowMeasurement?()
  }

  @ViewBuilder
  private func workedSection(
    items: [WorkedItem],
    kind: TranscriptWorkedSectionKind
  ) -> some View {
    let key: TranscriptDisclosureStore.Key =
      kind == .planning ? .turn(turnId) : .turnImplementation(turnId)
    if !items.isEmpty || turn.defersWorkedSection(kind) {
      let isExpanded = isExpanded(key)
      let deferredDetailItemID =
        turn.defersWorkedSection(kind)
        ? turn.deferredDetailItemId
        : nil
      VStack(alignment: .leading, spacing: 12) {
        if turn.isWorkedSectionLive(kind), !hasAutoCollapsed {
          workedHeader(
            label: sectionLabel(kind),
            showsChevron: false,
            expanded: isExpanded,
            deferredDetailItemID: nil
          )
        } else {
          Button {
            let change = {
              if isExpanded {
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
              expanded: isExpanded,
              deferredDetailItemID: deferredDetailItemID
            )
            .contentShape(Rectangle())
          }
          .buttonStyle(TranscriptWorkedSectionButtonStyle())
        }

        TranscriptDisclosureContentReveal(isExpanded: isExpanded && !items.isEmpty) {
          VStack(alignment: .leading, spacing: 12) {
            TurnItemsView(
              items: items,
              turnId: turnId,
              isTurnActive: isGenerating,
              animationPresentation: textAnimationPresentation,
              animationEnabled: textAnimationPresentation.animationsEnabled
            )
          }
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
