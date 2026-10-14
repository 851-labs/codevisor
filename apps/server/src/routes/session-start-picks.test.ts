import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { SessionSummary } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import {
  jsonRequest,
  makeServices,
  run,
  runningServers,
  startWithApp,
  tempDirs
} from "../test-support.js"

describe("a new chat's starting picks", () => {
  it("starts a chat an agent creates on its parent's picks", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-session-config-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const parent = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    await run(
      services.db.replaceSessionConfigSelections(
        parent.id,
        { model: "model-saved", reasoning: "high", tone: "tone-removed" },
        { tone: "tone-removed" }
      )
    )
    const otherHarness = await run(
      services.db.createSession({ projectId: project.id, harnessId: "other" })
    )
    await run(services.db.replaceSessionConfigSelections(otherHarness.id, { model: "other-model" }))
    const server = await startWithApp(services)
    runningServers.push(server)
    const create = async (body: Readonly<Record<string, unknown>>) =>
      (
        (await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({ projectId: project.id, harnessId: "codex", ...body }),
          method: "POST"
        })) as { readonly body: SessionSummary }
      ).body.configSelections

    const inherited = { model: "model-saved", reasoning: "high" }
    expect(await create({ parentSessionId: parent.id })).toEqual(inherited)
    expect(
      await create({ parentSessionId: parent.id, configSelections: { model: "model-picked" } })
    ).toEqual({ model: "model-picked" })
    expect(await create({ parentSessionId: otherHarness.id })).toBeUndefined()
    const workspace = (
      (await jsonRequest(server, "/v1/workspaces", {
        body: JSON.stringify({
          workspace: { id: "ws-child", projectId: project.id, name: "Child", hasCustomName: false },
          session: { projectId: project.id, harnessId: "codex", parentSessionId: parent.id }
        }),
        method: "POST"
      })) as { readonly body: { readonly session: SessionSummary } }
    ).body
    expect(workspace.session.configSelections).toEqual(inherited)
    expect(agents.startSelections).toEqual([
      inherited,
      { model: "model-picked" },
      undefined,
      inherited
    ])
  })
})
