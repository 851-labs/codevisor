import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { Harness } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { observableFixture } from "../changes-test-support.js"
import {
  jsonRequest,
  makeServices,
  run,
  runningServers,
  startWithApp,
  waitFor
} from "../test-support.js"

describe("archived chats and update turn accounting", () => {
  it("ends an archived chat's turn even when its prompt never settles", async () => {
    const { agents, services } = await makeServices("server-a")
    const turns: Array<string> = observableFixture([])
    const lifecycle = {
      beginBundledAppUpdate: async () => {},
      beginInstall: async () => ({ terminalId: "unused" }),
      beginUpdate: async () => ({ queued: false }),
      bundledAppInfo: async () => undefined,
      cancelPendingUpdate: async () => {},
      checkForUpdates: async () => [],
      decorateHarnesses: async (list: ReadonlyArray<Harness>) => list,
      forcePendingUpdate: async () => {},
      beginUninstall: async () => {},
      isGated: () => false,
      notifyTurnEnded: (harnessId: string) => turns.push(`end ${harnessId}`),
      notifyTurnStarted: (harnessId: string) => turns.push(`start ${harnessId}`),
      onGateReleased: () => () => {},
      reconcileOnStartup: async () => {},
      startPeriodicChecks: () => () => {},
      subscribe: () => () => {}
    }
    const server = await startWithApp({ ...services, lifecycle })
    runningServers.push(server)

    const folder = join(mkdtempSync(join(tmpdir(), "codevisor-archive-turn-")), "repo")
    mkdirSync(folder, { recursive: true })
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: folder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    const session = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ harnessId: "codex", projectId: project.id, title: "Working" }),
        method: "POST"
      })
    ).body as { readonly id: string }
    await jsonRequest(server, "/v1/workspaces/working", {
      body: JSON.stringify({ projectId: project.id, name: "Working", hasCustomName: false }),
      method: "PUT"
    })
    await jsonRequest(server, `/v1/sessions/${session.id}`, {
      body: JSON.stringify({ workspaceId: "working" }),
      method: "PATCH"
    })

    // The fake's "slow prompt" stays in flight until released, and closing
    // its runtime does not settle it — like a turn waiting on a question.
    await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
      body: JSON.stringify({ text: "slow prompt" }),
      method: "POST"
    })
    await waitFor(() => turns.includes("start codex"))

    await jsonRequest(server, "/v1/workspaces/working", {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    expect(turns).toEqual(["start codex", "end codex"])

    // The prompt settling late must not end the turn a second time.
    agents.releasePrompt()
    await waitFor(async () => (await run(services.db.listPromptQueue(session.id))).length === 0)
    expect(turns).toEqual(["start codex", "end codex"])
  })

  it("never holds an update behind a turn an archived chat starts after its archive", async () => {
    const { agents, services } = await makeServices("server-a")
    const server = await startWithApp(services)
    runningServers.push(server)

    const folder = join(mkdtempSync(join(tmpdir(), "codevisor-archive-late-turn-")), "repo")
    mkdirSync(folder, { recursive: true })
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: folder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    const session = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ harnessId: "codex", projectId: project.id, title: "Background" }),
        method: "POST"
      })
    ).body as { readonly id: string; readonly agentSessionId: string }
    await jsonRequest(server, "/v1/workspaces/background", {
      body: JSON.stringify({ projectId: project.id, name: "Background", hasCustomName: false }),
      method: "PUT"
    })
    await jsonRequest(server, `/v1/sessions/${session.id}`, {
      body: JSON.stringify({ workspaceId: "background" }),
      method: "PATCH"
    })
    // The harness's event pipe, held the way an in-flight event holds it
    // while the archive tears the runtime down.
    const sink = agents.sinks.get(session.agentSessionId)
    expect(sink).toBeDefined()

    await jsonRequest(server, "/v1/workspaces/background", {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    // A background task finishing wakes the agent just after the archive.
    // Its runtime is closing, so this turn's end event never arrives.
    await sink?.({
      kind: "session.updated",
      subjectId: session.agentSessionId,
      payload: { initiatedBy: "agent", turnId: "turn-late", turnState: "started" }
    })

    await waitFor(
      async () =>
        ((await jsonRequest(server, "/v1/restart/drain")).body as { remaining: number })
          .remaining === 0
    )
    await jsonRequest(server, "/v1/restart/drain", { body: "{}", method: "POST" })
    await waitFor(
      async () =>
        ((await jsonRequest(server, "/v1/restart/drain")).body as { state: string }).state ===
        "drained"
    )
  })
})
