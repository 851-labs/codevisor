import SwiftUI
import CodevisorCore
import ACPKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

extension ChatScreen {
  var composerOverlay: some View {
    let childAgents = visibleChildAgents
    let threads = visibleThreads
    return VStack(spacing: ComposerGlassStyle.clusterSpacing) {
      if childAgents != nil || threads != nil {
        ChildAgentsRowLayout {
          HStack(spacing: ComposerGlassStyle.clusterSpacing) {
            if let childAgents {
              ChildAgentsPill(content: childAgents, glassNamespace: composerGlassNamespace)
            }
            if let threads {
              BotThreadsPill(content: threads, glassNamespace: composerGlassNamespace)
            }
          }
          .padding(.leading, composerFieldLeadingInset)
          if showsTranscriptScrollControls {
            transcriptScrollControls
          }
        }
      }
      if let todos = controller.visibleTodos {
        TodoPanelView(
          plan: todos,
          isExpanded: $controller.isTodosExpanded,
          glassNamespace: composerGlassNamespace
        )
        .transition(Motion.unfold(reduceMotion: reduceMotion, anchor: .bottom))
      }
      if controller.supportsGoals, !controller.isGoalEditing {
        if let model = controller.model {
          LiveGoalBannerView(
            controller: controller,
            model: model,
            glassNamespace: composerGlassNamespace
          )
        } else if let goal = controller.draftGoal {
          GoalBannerView(
            controller: controller,
            goal: goal,
            glassNamespace: composerGlassNamespace
          )
        }
      }
      if showsPromptQueue {
        PromptQueueView(
          controller: controller,
          glassNamespace: composerGlassNamespace,
          onEditInComposer: { item in
            controller.beginEditingQueuedPrompt(item)
            focus.focusComposer()
          }
        )
      }
      composerNoticeRail
      ComposerCard(
        controller: controller,
        onTextViewReady: { textView in
          focus.composerTextView = textView
          if let chatId = controller.serverSession?.id {
            focus.registerComposer(textView, forChat: chatId)
          }
        },
        focus: focus,
        focusChatId: controller.serverSession?.id,
        glassNamespace: composerGlassNamespace
      )
      .onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: {
        composerCardHeight = $0
      }
    }
    .onPreferenceChange(ComposerSlashPalettePresentedPreference.self) { isSlashPalettePresented = $0 }
    .padding(.horizontal, Self.composerHorizontalPadding)
    .frame(maxWidth: Self.composerMaxWidth)
    .padding(.bottom, Self.composerBottomMargin)
    .padding(.top, Self.composerTopPadding)
    .frame(maxWidth: .infinity)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.height
    } action: {
      composerHeight = $0
      presentationSurface.updateComposerHeight($0)
    }
    .animation(
      Motion.quick(reduceMotion: reduceMotion),
      value: visibleComposerGlassElements(showsChildAgents: childAgents != nil, showsThreads: threads != nil)
    )
  }

  var showsChildAgentsRow: Bool {
    !isReadOnly && (visibleChildAgents != nil || visibleThreads != nil)
  }

  private var visibleThreads: BotThreadsPillContent? {
    guard presentsBotConversation, !isSlashPalettePresented, let session = controller.serverSession,
      let bot = environment.bots.bot(forSession: session.id, serverId: session.serverId)
    else { return nil }
    let threads = environment.botThreads.threads(of: bot)
    return threads.isEmpty ? nil : BotThreadsPillContent(bot: bot, threads: threads)
  }

  private var visibleChildAgents: ChildAgentsPillContent? {
    guard !isSlashPalettePresented, let workspaceChildAgents, let workspace = hostWorkspace else { return nil }
    return workspaceChildAgents.pill(for: workspace)
  }

  private var composerFieldLeadingInset: CGFloat {
    ComposerSlimLayout.isActive(usesSlimComposer, for: controller) ? ComposerSlimLayout.fieldLeadingInset : 0
  }

  private var hostWorkspace: Workspace? {
    let sessionWorkspaceId = controller.serverSession.flatMap { environment.workspaces.workspaceId(forSession: $0.id) }
    return (sessionWorkspaceId ?? controller.hostWorkspaceId).flatMap { environment.workspaces.workspace(id: $0) }
  }

  var hasPromptQueue: Bool {
    !presentsBotConversation && controller.hasQueuedMessages
  }

  func updatePromptQueueVisibility(_ hasQueue: Bool) {
    let sentToQueue = queueSends.sentSinceLastCheck(in: controller)
    if hasQueue, !sentToQueue {
      withTransaction(\.disablesAnimations, true) { showsPromptQueue = true }
    } else if hasQueue {
      withAnimation(Motion.entrance(reduceMotion: reduceMotion)) { showsPromptQueue = true }
    } else {
      withAnimation(Motion.glassMorph(reduceMotion: reduceMotion)) { showsPromptQueue = false }
    }
  }

  @ViewBuilder
  var composerNoticeRail: some View {
    if let message = controller.configurationValidationError {
      ComposerNoticeRail(
        message,
        kind: .error,
        actionTitle: "Retry",
        action: {
          Task { await controller.retryExistingSessionCapabilities() }
        }
      )
    } else if let message = controller.configurationAdjustmentMessage {
      ComposerNoticeRail(
        message,
        kind: .warning,
        onDismiss: { controller.dismissConfigurationAdjustment() }
      )
    }
    if let message = controller.modelUnavailableMessage {
      ComposerNoticeRail(
        message,
        kind: .warning,
        onDismiss: { controller.dismissModelUnavailableNotice() }
      )
    }
    if let message = controller.modelFallbackMessage {
      ComposerNoticeRail(
        message,
        kind: .warning,
        systemImage: "arrow.triangle.branch",
        onDismiss: { controller.dismissModelFallback() }
      )
    }
  }

  func visibleComposerGlassElements(showsChildAgents: Bool, showsThreads: Bool = false) -> [ComposerGlassElement] {
    let hasTodos = controller.visibleTodos != nil
    return ComposerGlassElements.visible(
      showsChildAgents: showsChildAgents,
      showsThreads: showsThreads,
      hasTodos: hasTodos,
      showsGoal: controller.supportsGoals && !controller.isGoalEditing
        && (controller.goal ?? controller.draftGoal) != nil
    )
  }
}
