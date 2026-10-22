import type { RestartDrainState, UpdateInfo } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { idleRouteState, idleUpdateRun, makeServices } from "./test-support.js"
import { withRestartDrain } from "./update-info-publish.js"

const release: UpdateInfo = {
  channel: "stable",
  currentVersion: "0.1.0",
  latestVersion: "0.2.0",
  migrationState: "idle",
  updateAvailable: true
}

const drainState = (overrides: Partial<RestartDrainState>): RestartDrainState => ({
  state: "draining",
  remaining: 0,
  startedAt: "2026-10-21T00:00:00.000Z",
  pausedSessionIds: [],
  ...overrides
})

const progressFor = async (
  drain: RestartDrainState,
  updatingHarnessId?: string,
  info: UpdateInfo = release
) => {
  const { services } = await makeServices("server-a")
  const idle = idleRouteState()
  const run = idleUpdateRun()
  const routeState = {
    ...idle,
    restart: { ...idle.restart, state: () => drain },
    updateRun: {
      ...run,
      state: () => ({
        ...run.state(),
        ...(updatingHarnessId === undefined ? {} : { currentHarnessId: updatingHarnessId })
      })
    }
  }
  return withRestartDrain(services, routeState, info).lastApply
}

describe("server update progress while chats are paused", () => {
  it.each([
    ["Pausing 1 chat for the update", drainState({ remaining: 1 }), undefined, "draining"],
    ["Pausing 3 chats for the update", drainState({ remaining: 3 }), undefined, "draining"],
    ["Updating Claude Code first", drainState({ state: "drained" }), "claude-code", "draining"],
    ["Updating retired-cli first", drainState({ state: "drained" }), "retired-cli", "draining"],
    ["Restarting to install the update", drainState({ state: "drained" }), undefined, "installing"]
  ] as const)("says “%s”", async (message, drain, harnessId, state) => {
    expect(await progressFor(drain, harnessId)).toMatchObject({ state, message })
  })

  it("keeps a failed install visible while chats are still pausing", async () => {
    const failed = {
      ...release,
      lastApply: { state: "failed" as const, message: "disk full", at: "2026-10-21T00:00:01.000Z" }
    }
    expect(await progressFor(drainState({ remaining: 2 }), undefined, failed)).toEqual(
      failed.lastApply
    )
  })

  it("leaves server progress alone while only a harness's chats are paused", async () => {
    expect(
      await progressFor(drainState({ state: "drained", harnessIds: ["codex"] }), "codex")
    ).toBeUndefined()
  })
})
