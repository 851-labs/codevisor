import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import {
  jsonRequest,
  makeServices,
  pluginsStub,
  runningServers,
  startWithApp,
  tempDirs
} from "../test-support.js"

/// DELETE /v1/plugins/:pluginId/link — detaching a linked dev checkout.

describe("plugin unlink route", () => {
  it("unlinks the plugin and closes its panes like an uninstall", async () => {
    const { services } = await makeServices("server-a")
    const calls: Array<Array<unknown>> = []
    const server = await startWithApp({ ...services, plugins: pluginsStub(calls) })
    runningServers.push(server)

    const root = mkdtempSync(join(tmpdir(), "codevisor-plugin-unlink-"))
    tempDirs.push(root)
    const projectFolder = join(root, "project")
    mkdirSync(projectFolder)
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: projectFolder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    await jsonRequest(server, "/v1/workspaces/ws-dev", {
      body: JSON.stringify({ hasCustomName: false, name: "ws-dev", projectId: project.id }),
      method: "PUT"
    })
    for (const [paneId, providerId] of [
      ["plugin-pane", "plugin:owner.example"],
      ["other-pane", "plugin:owner.other"]
    ] as const) {
      await jsonRequest(server, `/v1/workspaces/ws-dev/panes/${paneId}`, {
        body: JSON.stringify({ paneType: "main", providerId, title: "Pane" }),
        method: "PUT"
      })
    }

    const unlinked = await jsonRequest(server, "/v1/plugins/owner.example/link", {
      method: "DELETE"
    })
    expect(unlinked.status).toBe(200)
    expect(unlinked.body).toEqual({ plugins: [] })
    expect(calls).toContainEqual(["unlink", "owner.example"])

    const panes = (await jsonRequest(server, "/v1/workspace-panes")).body as Array<{
      id: string
    }>
    expect(panes.map((pane) => pane.id)).toEqual(["other-pane"])

    // An unknown plugin is refused before anything is touched.
    const missing = await jsonRequest(server, "/v1/plugins/owner.ghost/link", {
      method: "DELETE"
    })
    expect(missing.status).toBe(404)
    expect(calls).not.toContainEqual(["unlink", "owner.ghost"])
  })
})
