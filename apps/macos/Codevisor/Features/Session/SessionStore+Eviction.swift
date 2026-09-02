import Foundation
import Observation
import CodevisorCore
import ACPKit

// MARK: - Eviction

extension SessionStore {
    /// Bumps a session to most-recently-used and evicts idle controllers
    /// beyond the cache limit. Pane groups are deliberately NOT evicted:
    /// their panes hold live server PTYs that must survive navigation.
    func noteAccess(_ key: SessionKey) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        evictIdleControllers()
    }

    func isRunning(_ key: SessionKey) -> Bool {
        guard let controller = controllers[key] else { return false }
        return Self.isInProgress(controller) || controller.isConnecting
    }

    /// Frees the least-recently-used cached controllers, keeping every
    /// controller that could still produce activity: the open session,
    /// anything running/connecting/in setup, sessions the agent will return
    /// to on its own (background tasks, active goals). Evicted sessions
    /// reload from server history on next open.
    func evictIdleControllers() {
        let idle = accessOrder.filter { id in
            guard let controller = controllers[id] else { return false }
            return id != openSessionKey
                && !isRunning(id)
                && !controller.isWaitingOnBackgroundTasks
                && controller.goal?.status != .active
        }
        guard idle.count > Self.maxIdleControllers else { return }
        for id in idle.dropLast(Self.maxIdleControllers) {
            let controller = controllers.removeValue(forKey: id)
            controller?.onScrollStateChange = nil
            controller?.model?.shutdown()
            scrollStates[id] = nil
            transcriptSurfaces.remove(serverID: id.serverId, sessionID: id.sessionId)
        }
    }
}
