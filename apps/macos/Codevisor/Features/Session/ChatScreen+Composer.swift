import SwiftUI
import CodevisorCore
import ACPKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

// MARK: - Composer

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
      // Hidden while editing: the composer IS the goal UI in that mode.
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
      if !controller.queuedPrompts.isEmpty {
        PromptQueueView(
          controller: controller,
          isExpanded: $isQueueExpanded,
          glassNamespace: composerGlassNamespace
        )
      }
      composerNoticeRail
      // Sibling of the notice rail rather than another branch of it: a
      // stalled turn needs its escape hatch even while a dismissible
      // configuration warning is on screen.
      StalledTurnNoticeView(controller: controller)
      // ComposerCard owns all of its states, including blocking agent
      // questions and plan approvals, so they share one stable glass
      // identity while the content and surface geometry change.
      ComposerCard(
        controller: controller,
        placeholder: "Ask for follow-up changes",
        onTextViewReady: { textView in
          // REGISTRATION ONLY — mounting never takes focus. The
          // container's open sequence is the single writer of the
          // initial focus (it targets the routed chat, applying
          // the moment that chat's composer registers); every
          // later move is an explicit user intent. Racing grabs
          // from N panes mounting in arbitrary layout order is
          // exactly what this replaces.
          focus.composerTextView = textView
          if let chatId = controller.serverSession?.id {
            focus.registerComposer(textView, forChat: chatId)
          }
        },
        // The question picker DOES take focus on mount (unlike the
        // composer registration above): its mount is an event — a
        // blocking question arrived and replaced the composer.
        focus: focus,
        focusChatId: controller.serverSession?.id,
        glassNamespace: composerGlassNamespace
      )
      // Keep the transcript mask in sync as the shared composer changes
      // size between its ordinary and question content.
      .onGeometryChange(for: CGSize.self) { geometry in
        geometry.size
      } action: { size in
        composerMaskSize = size
        presentationSurface.updateComposerMaskSize(size)
      }
    }
    .padding(.horizontal, 24)
    .frame(maxWidth: 880)
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
    .animation(Motion.quick(reduceMotion: reduceMotion), value: isQueueExpanded)
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
    // A refusal-driven model swap is independent of the two notices above:
    // it can happen mid-chat long after configuration settled, so it gets
    // its own slot rather than another branch.
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
      hasQueuedPrompts: !controller.queuedPrompts.isEmpty
    )
  }
}
