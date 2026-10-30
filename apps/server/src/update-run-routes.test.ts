import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { observableFixture } from "./changes-test-support.js"
import { updateResumeNotice } from "./restart-notice.js"
import { fakeHarnessLifecycle } from "./routes/harness-auth-test-support.js"
import type { RunningCodevisorServer } from "./server.js"
import {
  bodyId,
  jsonRequest,
  makeServices,
  run,
  startWithApp,
  tempDirs,
  waitFor
} from "./test-support.js"
import { field } from "./unknown-values.js"

const harnessUpdates = (steps: Array<string>, release: Promise<void> = Promise.resolve()) =>
  fakeHarnessLifecycle({
    prepareUpdate: async (harnessId) => {
      steps.push(`prepare ${harnessId}`)
      return { phase: "updating" }
    },
    applyUpdate: async (harnessId) => {
      steps.push(`install ${harnessId}`)
      await release
      return true
    },
    cancelUpdate: (harnessId) => {
      steps.push(`cancel ${harnessId}`)
    },
    decorateHarnesses: async (list) => list,
    isGated: () => false,
    notifyTurnEnded: () => {},
    notifyTurnStarted: () => {},
    onGateReleased: () => () => {},
    subscribe: () => () => {}
  })

const releaseServer = {
  channel: "stable",
  checkedAt: "2026-06-30T00:00:00.000Z",
  currentVersion: "0.1.0",
  latestVersion: "0.2.0",
  migrationState: "idle" as const,
  updateAvailable: true
}

const openChat = async (
  server: RunningCodevisorServer,
  harnessId: string,
  title: string
): Promise<string> => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-update-run-"))
  tempDirs.push(root)
  const folder = join(root, title.toLowerCase())
  mkdirSync(folder)
  const created = await jsonRequest(server, "/v1/projects", {
    body: JSON.stringify({ folderPath: folder }),
    method: "POST"
  })
  const projectId = bodyId(created)
  const session = await jsonRequest(server, "/v1/sessions", {
    body: JSON.stringify({ projectId, harnessId, title }),
    method: "POST"
  })
  return bodyId(session)
}

const textOf = (input: string | { readonly text: string }): string =>
  typeof input === "string" ? input : input.text

const runState = async (server: RunningCodevisorServer): Promise<unknown> =>
  field((await jsonRequest(server, "/v1/updates/run")).body, "state")

const prompt = (server: RunningCodevisorServer, sessionId: string, text: string) =>
  jsonRequest(server, `/v1/sessions/${sessionId}/prompt`, {
    body: JSON.stringify({ text }),
    method: "POST"
  })

describe("update runs", () => {
  it("keeps chats paused from the harness install through the server restart", async () => {
    const { agents, services } = await makeServices("server-a")
    const steps: Array<string> = observableFixture([])
    const install = Promise.withResolvers<void>()
    const server = await startWithApp(
      { ...services, lifecycle: harnessUpdates(steps, install.promise) },
      undefined,
      {
        updater: {
          check: async () => releaseServer,
          apply: async () => {
            steps.push("restart server")
          }
        }
      }
    )
    const chat = await openChat(server, "codex", "Busy")
    await prompt(server, chat, "prompt until cancelled")
    await waitFor(() => agents.prompts.length === 1)

    const started = await jsonRequest(server, "/v1/updates/run", {
      body: JSON.stringify({ harnessIds: ["codex"], serverChannel: "stable" }),
      method: "POST"
    })

    expect(started.status).toBe(202)
    expect(started.body).toMatchObject({
      run: { state: "pausing", harnessIds: ["codex"] },
      server: { accepted: true, targetVersion: "0.2.0", draining: true }
    })
    await waitFor(() => steps.includes("install codex"))
    expect(await runState(server)).toBe("updating")
    expect((await jsonRequest(server, "/v1/update")).body).toMatchObject({
      lastApply: { state: "draining", message: "Updating Codex first" }
    })
    expect((await prompt(server, chat, "while updating")).status).toBe(409)
    const cancelled = await jsonRequest(server, "/v1/updates/run", { method: "DELETE" })
    expect(cancelled.status).toBe(409)

    install.resolve()
    await waitFor(() => steps.includes("restart server"))
    expect(steps).toEqual(["prepare codex", "install codex", "restart server"])
    expect(agents.cancellations).toHaveLength(1)
    expect(await runState(server)).toBe("restarting")
    expect((await jsonRequest(server, "/v1/restart/drain")).body).toMatchObject({
      state: "drained",
      pausedSessionIds: [chat]
    })
    expect(agents.prompts).toHaveLength(1)
  })

  it("pauses only the updating harness's chats, then continues them once", async () => {
    const { agents, services } = await makeServices("server-a")
    const steps: Array<string> = observableFixture([])
    const install = Promise.withResolvers<void>()
    const server = await startWithApp({
      ...services,
      lifecycle: harnessUpdates(steps, install.promise)
    })
    const updating = await openChat(server, "codex", "Updating")
    const other = await run(
      services.db.createSession({
        deferAgentSession: true,
        harnessId: "claude-code",
        projectId: (await run(services.db.getSessionSummary(updating))).projectId,
        title: "Other"
      })
    )
    await prompt(server, updating, "prompt until cancelled")
    await waitFor(() => agents.prompts.length === 1)

    await jsonRequest(server, "/v1/updates/run", {
      body: JSON.stringify({ harnessIds: ["codex"] }),
      method: "POST"
    })
    await waitFor(() => steps.includes("install codex"))

    expect((await jsonRequest(server, "/v1/restart/drain")).body).toMatchObject({
      state: "drained",
      harnessIds: ["codex"],
      pausedSessionIds: [updating]
    })
    expect((await prompt(server, updating, "held back")).status).toBe(409)
    expect((await prompt(server, other.id, "still welcome")).status).toBe(202)

    install.resolve()
    await waitFor(async () => (await runState(server)) === "idle")
    await waitFor(() => agents.prompts.length === 3)
    const continued = agents.prompts.filter(([sessionId]) => sessionId === "agent-codex-updating")
    expect(continued.map(([, input]) => textOf(input))).toEqual([
      "prompt until cancelled",
      updateResumeNotice([])
    ])
    expect(agents.cancellations).toHaveLength(1)
  })

  it("lets the user cancel while chats are still pausing", async () => {
    const { agents, services } = await makeServices("server-a")
    const steps: Array<string> = observableFixture([])
    const interrupting = Promise.withResolvers<void>()
    const interrupted = Promise.withResolvers<void>()
    const server = await startWithApp({
      ...services,
      agents: {
        ...services.agents,
        cancel: () =>
          Effect.promise(async () => {
            interrupting.resolve()
            await interrupted.promise
            return { runtimeState: "reusable" as const }
          })
      },
      lifecycle: harnessUpdates(steps)
    })
    const chat = await openChat(server, "codex", "Stuck")
    await prompt(server, chat, "prompt until cancelled")
    await waitFor(() => agents.prompts.length === 1)
    await jsonRequest(server, "/v1/updates/run", {
      body: JSON.stringify({ harnessIds: ["codex"] }),
      method: "POST"
    })

    await interrupting.promise

    const cancelled = jsonRequest(server, "/v1/updates/run", { method: "DELETE" })
    interrupted.resolve()
    await waitFor(async () => (await runState(server)) === "idle")

    expect((await cancelled).status).toBe(200)
    expect((await jsonRequest(server, "/v1/updates/run", { method: "PUT" })).status).toBe(404)
    expect(steps).toEqual(["prepare codex", "cancel codex"])
  })
})
