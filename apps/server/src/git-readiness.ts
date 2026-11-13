import { setTimeout as delay } from "node:timers/promises"

import { gitInstallation, type GitInstallation } from "@codevisor/worktrees"

import { startFirstRunProjectImport } from "./first-run-project-import.js"
import { backfillProjectRepoUrls } from "./routes/project-repo-identity.js"
import {
  swallowError,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout
} from "./server-context.js"
import { reconcileWorktreeArchives } from "./worktree-reconcile.js"

export interface GitReadinessDeps {
  readonly installation: () => Promise<GitInstallation>
  readonly sleep: (ms: number, signal: AbortSignal) => Promise<void>
}

export const startGitDependentWork = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig,
  deps: GitReadinessDeps = systemGitReadiness
): (() => void) => {
  const waiting = new AbortController()
  void whenGitReady(waiting.signal, deps).then((isReady) => {
    if (isReady) startStartupGitWork(services, fanout, config)
  })
  return () => waiting.abort()
}

const gitRecheckIntervalMs = 2_000

const whenGitReady = async (signal: AbortSignal, deps: GitReadinessDeps): Promise<boolean> => {
  while (!signal.aborted) {
    const installation = await deps.installation()
    if (installation.state === "ready") return true

    await deps.sleep(gitRecheckIntervalMs, signal)
  }
  return false
}

const systemGitReadiness: GitReadinessDeps = {
  installation: gitInstallation,
  sleep: (ms, signal) => delay(ms, undefined, { signal, ref: false }).catch(swallowError)
}

const startStartupGitWork = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig
): void => {
  void backfillProjectRepoUrls(
    services.db,
    config.id,
    fanout,
    services.resolveGitEnvironment
  ).catch(swallowError)
  void reconcileWorktreeArchives(services, fanout, config).catch(swallowError)
  void startFirstRunProjectImport(services, fanout, config)
}
