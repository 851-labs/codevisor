import Foundation
import Observation
import CodevisorCore
import ACPKit

// MARK: - Activity

extension SessionStore {
    /// Whether the session is doing work the user should see as activity:
    /// generating a response, running pre-chat setup (worktree creation, agent
    /// start), or waiting on background work it will return to on its own.
    ///
    /// Deliberately excludes the connection pulse from opening a session —
    /// connecting is loading, not activity, so the leading icon keeps showing
    /// the harness icon and sidebar ordering does not make an idle row jump
    /// while its transcript connects.
    func isInProgress(_ session: ChatSession) -> Bool {
        guard let controller = controllers[SessionKey(session)] else {
            return session.sidebarState == .inProgress
        }
        return Self.isInProgress(controller)
    }

    /// Whether any cached session on a given server is doing real work
    /// (generating a response or running pre-chat setup). Gates app/server
    /// updates so a restart never interrupts a live turn. The transient
    /// connect pulse on first open deliberately does not block an update.
    func hasActiveSessions(onServer serverId: String) -> Bool {
        _ = activityRevision
        return controllers.values.contains { controller in
            controller.serverSession?.serverId == serverId && Self.isActivelyWorking(controller)
        }
    }

    /// Whether any chat bound to `harnessId` on a machine is mid-turn — gates
    /// the immediate harness update offer (updating a busy harness waits for
    /// the when-idle flow instead).
    func hasActiveSessions(forHarness harnessId: String, onServer serverId: String) -> Bool {
        _ = activityRevision
        return controllers.values.contains { controller in
            controller.serverSession?.serverId == serverId
                && (controller.activeHarnessId ?? controller.serverSession?.harnessId) == harnessId
                && Self.isActivelyWorking(controller)
        }
    }

    static func isActivelyWorking(_ controller: SessionController) -> Bool {
        controller.isSending
            || controller.setupPhases.contains(where: \.isRunning)
    }

    static func isInProgress(_ controller: SessionController) -> Bool {
        // A first-send optimistic row exists before the provider flips
        // `model.isSending`. Keep it in its final visible tier from insertion
        // onward instead of briefly adding it as idle and reordering it again.
        controller.pendingUserMessage != nil
            || isActivelyWorking(controller)
            || controller.isWaitingOnBackgroundTasks
    }

    /// Whether the session is blocked waiting on the user — an agent question or
    /// a plan-approval prompt. The model isn't busy, it needs a response, so the
    /// sidebar surfaces this as the attention badge instead of the spinner.
    func isWaitingOnUser(_ session: ChatSession) -> Bool {
        guard let controller = controllers[SessionKey(session)] else {
            return session.actionRequired
        }
        return session.actionRequired
            || controller.pendingQuestion != nil
            || controller.pendingPlanApproval
    }
}
