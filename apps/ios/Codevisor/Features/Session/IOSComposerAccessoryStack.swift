import CodevisorCore
import CodevisorUI
import SwiftUI

/// The iOS accessory composition is touch-specific, while every source of
/// truth and reusable surface remains shared with macOS. Keeping this in a
/// child view also confines plan/fallback/stall Observation invalidations to
/// the small bottom-chrome subtree instead of the virtual transcript host.
struct IOSComposerAccessoryStack: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var controller: SessionController
    let isComposerExpanded: Bool
    let maximumTodoHeight: CGFloat
    let glassNamespace: Namespace.ID

    private var hasCriticalAccessory: Bool {
        controller.configurationValidationError != nil
            || controller.isTakingLongerThanExpected
    }

    private var hasInformationalAccessory: Bool {
        guard !isComposerExpanded else { return false }
        return controller.visibleTodos != nil
            || !controller.queuedPrompts.isEmpty
            || (controller.configurationValidationError == nil
                && controller.configurationAdjustmentMessage != nil)
            || controller.modelFallbackMessage != nil
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
                    .transition(Motion.unfold(reduceMotion: reduceMotion, anchor: .bottom))
                }

                if !controller.queuedPrompts.isEmpty {
                    IOSPromptQueueAccessory(
                        controller: controller,
                        glassNamespace: glassNamespace
                    )
                    .transition(Motion.unfold(reduceMotion: reduceMotion, anchor: .bottom))
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

            IOSStalledTurnNoticeView(controller: controller)
        }
        .padding(.bottom, hasVisibleAccessory ? ComposerGlassStyle.clusterSpacing : 0)
        .animation(Motion.quick(reduceMotion: reduceMotion), value: hasVisibleAccessory)
        .animation(Motion.quick(reduceMotion: reduceMotion), value: controller.visibleTodos != nil)
        .animation(
            Motion.quick(reduceMotion: reduceMotion),
            value: controller.queuedPrompts.map(\.id)
        )
        .animation(Motion.quick(reduceMotion: reduceMotion), value: controller.modelFallbackMessage)
        .animation(
            Motion.quick(reduceMotion: reduceMotion),
            value: controller.configurationValidationError
        )
        .animation(
            Motion.quick(reduceMotion: reduceMotion),
            value: controller.configurationAdjustmentMessage
        )
    }
}

/// Isolates provider-activity writes from SessionTranscriptView. These values
/// change during an active turn and should only invalidate this one caption
/// rail, mirroring the macOS stalled-turn view's Observation boundary.
private struct IOSStalledTurnNoticeView: View {
    let controller: SessionController

    var body: some View {
        if controller.isTakingLongerThanExpected {
            ComposerNoticeRail(
                "Taking longer than expected"
                    + (controller.providerActivityPhase.map { " during \($0.label)" } ?? ""),
                kind: .warning,
                systemImage: "clock.badge.exclamationmark",
                actionTitle: "Stop and reconnect",
                action: {
                    Task {
                        await controller.stop()
                        if !controller.isSending {
                            await controller.reconnect()
                        }
                    }
                }
            )
        }
    }
}
