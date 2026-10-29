import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct IOSComposerAccessoryStack: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Bindable var controller: SessionController
  let isComposerExpanded: Bool
  let maximumTodoHeight: CGFloat
  let glassNamespace: Namespace.ID
  let queueSendAnimation: IOSQueueSendAnimation
  @State private var isPresentingQueue = false

  private var visibleGoal: SessionGoal? {
    guard controller.supportsGoals, !controller.isGoalEditing else { return nil }
    return controller.model?.goal ?? controller.draftGoal
  }

  private var hasCriticalAccessory: Bool {
    controller.configurationValidationError != nil
  }

  private var hasInformationalAccessory: Bool {
    guard !isComposerExpanded else { return false }
    return controller.visibleTodos != nil
      || visibleGoal != nil
      || showsQueue
      || (controller.configurationValidationError == nil
        && controller.configurationAdjustmentMessage != nil)
      || controller.modelFallbackMessage != nil
      || controller.modelUnavailableMessage != nil
  }

  private var showsQueue: Bool {
    !controller.presentsBotConversation && controller.hasQueuedMessages
  }

  private var hasVisibleAccessory: Bool {
    hasCriticalAccessory || hasInformationalAccessory
  }

  var body: some View {
    VStack(spacing: ComposerGlassStyle.clusterSpacing) {
      if !isComposerExpanded {
        if let todos = controller.visibleTodos {
          TodoPanelView(
            plan: todos,
            isExpanded: $controller.isTodosExpanded,
            glassNamespace: glassNamespace,
            maximumExpandedHeight: maximumTodoHeight
          )
          .transition(.opacity)
        }

        if let goal = visibleGoal {
          IOSGoalAccessory(
            controller: controller,
            goal: goal,
            glassNamespace: glassNamespace
          )
          .transition(.asymmetric(insertion: .opacity, removal: .identity))
        }

        if showsQueue {
          IOSPromptQueueAccessory(
            controller: controller,
            glassNamespace: glassNamespace,
            isPresentingQueue: $isPresentingQueue,
            sendAnimation: queueSendAnimation
          )
          .transition(.opacity)
        }

        if controller.configurationValidationError == nil,
          let message = controller.configurationAdjustmentMessage
        {
          ComposerNoticeRail(
            message,
            kind: .warning,
            onDismiss: { controller.dismissConfigurationAdjustment() }
          )
          .transition(.opacity)
        }

        if let message = controller.modelUnavailableMessage {
          ComposerNoticeRail(
            message,
            kind: .warning,
            onDismiss: { controller.dismissModelUnavailableNotice() }
          )
          .transition(.opacity)
        }

        if let message = controller.modelFallbackMessage {
          ComposerNoticeRail(
            message,
            kind: .warning,
            systemImage: "arrow.triangle.branch",
            onDismiss: { controller.dismissModelFallback() }
          )
          .transition(.opacity)
        }
      }

      if let message = controller.configurationValidationError {
        ComposerNoticeRail(
          message,
          kind: .error,
          actionTitle: "Retry",
          action: {
            Task { await controller.retryExistingSessionCapabilities() }
          }
        )
        .transition(.opacity)
      }

    }
    .padding(.bottom, hasVisibleAccessory ? ComposerGlassStyle.clusterSpacing : 0)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: hasVisibleAccessory)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: controller.visibleTodos != nil)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: visibleGoal?.objective)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: visibleGoal?.status)
    .animation(
      Motion.quick(reduceMotion: reduceMotion),
      value: controller.queuedMessagePreviews.map(\.id)
    )
    .animation(Motion.quick(reduceMotion: reduceMotion), value: controller.modelFallbackMessage)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: controller.modelUnavailableMessage)
    .animation(
      Motion.quick(reduceMotion: reduceMotion),
      value: controller.configurationValidationError
    )
    .animation(
      Motion.quick(reduceMotion: reduceMotion),
      value: controller.configurationAdjustmentMessage
    )
    .popover(isPresented: $isPresentingQueue) {
      IOSPromptQueueSheet(controller: controller)
        .frame(idealWidth: 400, idealHeight: 480)
    }
  }
}
