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
      installMethods: async () => [],
      uninstallInfo: async () => ({ available: true }),
      beginUninstall: async () => ({
        terminalId: "unused",
        lifecycle: { phase: "uninstalling" as const }
      }),
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
})
