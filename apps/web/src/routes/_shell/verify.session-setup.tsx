import { createFileRoute } from "@tanstack/react-router"

import { SessionSetupView } from "../../features/session/SessionSetupView"
import type { SessionSetupPhaseInfo } from "../../lib/session-setup"

export const Route = createFileRoute("/_shell/verify/session-setup")({
  component: SessionSetupFixtureRoute
})

const manyLogs = Array.from({ length: 20 }, (_, index) => ({
  id: index,
  stream: index % 4 === 0 ? "stderr" : "stdout",
  text: `setup log ${String(index + 1).padStart(2, "0")}: ${
    index === 19 ? "final line should be visible at the bottom" : "preparing worktree output"
  }`
}))

function setupPhases(now: number): SessionSetupPhaseInfo[] {
  return [
    {
      id: "worktree-running",
      activeTitle: "Setting up worktree",
      completedTitle: "Set up worktree",
      failedTitle: "Could not set up worktree",
      startedAt: new Date(now - 12_000).toISOString(),
      outcome: "running",
      logs: manyLogs.slice(0, 3)
    },
    {
      id: "worktree-succeeded",
      activeTitle: "Setting up worktree",
      completedTitle: "Set up worktree",
      failedTitle: "Could not set up worktree",
      startedAt: new Date(now - 64_000).toISOString(),
      endedAt: new Date(now - 4_000).toISOString(),
      outcome: "succeeded",
      logs: [
        { id: 0, stream: "stdout", text: "created worktree" },
        { id: 1, stream: "stdout", text: "checked out branch" }
      ]
    },
    {
      id: "worktree-failed",
      activeTitle: "Setting up worktree",
      completedTitle: "Set up worktree",
      failedTitle: "Could not set up worktree",
      startedAt: new Date(now - 8_000).toISOString(),
      endedAt: new Date(now - 1_000).toISOString(),
      outcome: "failed",
      failureMessage: "fatal: a branch named 'codevisor/fix-auth' already exists",
      logs: manyLogs
    }
  ]
}

function SessionSetupFixtureRoute() {
  const phases = setupPhases(Date.now())
  return (
    <div className="bg-background h-full overflow-auto">
      <div className="mx-auto flex w-full max-w-[880px] flex-col gap-8 px-6 pt-10">
        <SessionSetupView phases={phases} />
      </div>
    </div>
  )
}
