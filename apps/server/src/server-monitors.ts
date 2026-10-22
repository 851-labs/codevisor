import { gitHostsOf } from "./infra/git-hosts.js"
import { startWorkspaceGitMonitor, type WorkspaceGitMonitor } from "./infra/workspace-git.js"
import { workspaceGitCheckout } from "./server-context.js"
import type {
  CodevisorServerConfig,
  CodevisorServerServices,
  EventFanout
} from "./server-context.js"

export const startWorkspaceGitMonitorIfEnabled = (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout
): WorkspaceGitMonitor | undefined => {
  if (config.workspaceGit !== true) return undefined
  return startWorkspaceGitMonitor({
    db: services.db,
    fanout,
    checkout: (workspace) => workspaceGitCheckout(services, config.id, workspace),
    environment: (directory) =>
      services.resolveGitEnvironment?.(directory) ?? Promise.resolve(process.env),
    pullRequestOf: gitHostsOf(services).github.findPullRequest
  })
}

export const subscribeSessionActivity = (
  config: CodevisorServerConfig,
  fanout: EventFanout,
  activeSessionIds: Set<string>
): (() => void) | undefined => {
  if (!config.sessionActivity) return undefined
  return fanout.subscribe((event) => {
    if (event.kind !== "session.attention.updated") return
    const payload = event.payload
    if (
      typeof payload !== "object" ||
      payload === null ||
      !("sidebarState" in payload) ||
      typeof payload.sidebarState !== "string"
    ) {
      return
    }
    const active = payload.sidebarState === "inProgress"
    if (active) {
      if (activeSessionIds.has(event.subjectId)) return
      activeSessionIds.add(event.subjectId)
    } else {
      if (!activeSessionIds.delete(event.subjectId)) return
    }
    config.sessionActivity?.update(event.subjectId, active)
  })
}

export const startSharedAccountSweep = (
  services: CodevisorServerServices,
  reconcile: () => void
): NodeJS.Timeout | undefined => {
  if (!services.sharedAccounts) return undefined
  return setInterval(reconcile, 30_000)
}
