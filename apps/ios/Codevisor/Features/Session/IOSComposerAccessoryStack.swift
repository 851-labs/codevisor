import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct IOSComposerAccessoryStack: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(AppEnvironment.self) private var environment
  @Bindable var controller: SessionController
  let isComposerExpanded: Bool
  let maximumTodoHeight: CGFloat
  let glassNamespace: Namespace.ID
  let holdsQueueEntrance: Bool
  @State private var isPresentingQueue = false
  @State private var showsQueue = false
  @State private var awaitsQueueEntrance = false
  @State private var queueSends = QueueSendObserver()

  private var visibleGoal: SessionGoal? {
    guard controller.supportsGoals, !controller.isGoalEditing else { return nil }
    return controller.model?.goal ?? controller.draftGoal
  }

  private var hasCriticalAccessory: Bool {
    controller.configurationValidationError != nil
  }

  private var agents: [ChatSession] {
    controller.serverSession.map(environment.projectList.children(of:)) ?? []
  }

  private var hasInformationalAccessory: Bool {
    guard !isComposerExpanded else { return false }
    return controller.visibleTodos != nil
      || !agents.isEmpty
      || visibleGoal != nil
      || (controller.configurationValidationError == nil
        && controller.configurationAdjustmentMessage != nil)
      || controller.modelFallbackMessage != nil
      || controller.modelUnavailableMessage != nil
  }

  private var hasQueue: Bool {
    !controller.presentsBotConversation && controller.hasQueuedMessages
  }

  private var presentsQueue: Bool {
    showsQueue && hasQueue
  }

  private var showsCollapsedQueue: Bool {
    presentsQueue && !isComposerExpanded
  }

  private var hasAccessoryOtherThanQueue: Bool {
    hasCriticalAccessory || hasInformationalAccessory
  }

  private var hasVisibleAccessory: Bool {
    hasAccessoryOtherThanQueue || showsCollapsedQueue
  }

  var body: some View {
    VStack(spacing: ComposerGlassStyle.clusterSpacing) {
      if !isComposerExpanded {
        if !agents.isEmpty {
          IOSAgentsAccessory(agents: agents, glassNamespace: glassNamespace)
            .transition(.opacity)
        }

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

        if presentsQueue {
          IOSPromptQueueAccessory(
            controller: controller,
            glassNamespace: glassNamespace,
            isPresentingQueue: $isPresentingQueue
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
    .animation(Motion.quick(reduceMotion: reduceMotion), value: hasAccessoryOtherThanQueue)
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
    .onChange(of: hasQueue, initial: true) { _, hasQueue in
      updateQueueVisibility(hasQueue)
    }
    .onChange(of: holdsQueueEntrance) { _, holds in
      if !holds { releaseQueueEntrance() }
    }
    .popover(isPresented: $isPresentingQueue) {
      IOSPromptQueueSheet(controller: controller)
        .frame(idealWidth: 400, idealHeight: 480)
    }
  }

  private func updateQueueVisibility(_ hasQueue: Bool) {
    let sentToQueue = queueSends.sentSinceLastCheck(in: controller)
    awaitsQueueEntrance = false
    if hasQueue, !sentToQueue {
      withTransaction(\.disablesAnimations, true) { showsQueue = true }
    } else if hasQueue, holdsQueueEntrance {
      awaitsQueueEntrance = true
    } else if hasQueue {
      enterQueue()
    } else {
      showsQueue = false
    }
  }

  private func releaseQueueEntrance() {
    guard awaitsQueueEntrance else { return }

    awaitsQueueEntrance = false
    enterQueue()
  }

  private func enterQueue() {
    withAnimation(Motion.entrance(reduceMotion: reduceMotion)) { showsQueue = true }
  }
}
