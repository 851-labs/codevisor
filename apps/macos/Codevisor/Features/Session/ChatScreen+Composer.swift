import SwiftUI
import CodevisorCore
import ACPKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

extension ChatScreen {
  var composerOverlay: some View {
    VStack(spacing: ComposerGlassStyle.clusterSpacing) {
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
      if !presentsBotConversation, !controller.queuedPrompts.isEmpty {
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
    .padding(.horizontal, Self.composerHorizontalPadding)
    .frame(maxWidth: Self.composerMaxWidth)
    .padding(.bottom, Self.composerBottomMargin)
    .padding(.top, 24)
    .frame(maxWidth: .infinity)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.height
    } action: {
      composerHeight = $0
      presentationSurface.updateComposerHeight($0)
    }
    .animation(Motion.quick(reduceMotion: reduceMotion), value: visibleComposerGlassElements)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: controller.queuedPrompts.map(\.id))
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

  var visibleComposerGlassElements: [ComposerGlassElement] {
    let hasTodos = controller.visibleTodos != nil
    return ComposerGlassElements.visible(
      hasTodos: hasTodos,
      showsGoal: controller.supportsGoals && !controller.isGoalEditing
        && (controller.goal ?? controller.draftGoal) != nil,
      hasQueuedPrompts: !presentsBotConversation && !controller.queuedPrompts.isEmpty
    )
  }
}
