import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { WorkspacePane } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { jsonRequest, run, start, tempDirs } from "../test-support.js"

describe("shared tab order over HTTP", () => {
  it("appends new tabs at the end and reorders them for every client", async () => {
    const { server, services } = await start()
    const folder = mkdtempSync(join(tmpdir(), "tab-order-http-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    await jsonRequest(server, "/v1/workspaces/alpha", {
      method: "PUT",
      body: JSON.stringify({ projectId: project.id, name: "alpha", hasCustomName: false })
    })
    for (const [id, title] of [
      ["00000000-0000-0000-0000-00000000000a", "Chat"],
      ["00000000-0000-0000-0000-00000000000b", "Terminal"],
      ["00000000-0000-0000-0000-00000000000c", "Browser"]
    ] as const) {
      await jsonRequest(server, `/v1/workspaces/alpha/panes/${id}`, {
        method: "PUT",
        body: JSON.stringify({ providerId: "codevisor", paneType: "terminal", title })
      })
    }
    const titles = async () =>
      ((await jsonRequest(server, "/v1/workspace-panes")).body as WorkspacePane[]).map(
        (pane) => pane.title
      )
    expect(await titles()).toEqual(["Chat", "Terminal", "Browser"])

    const reordered = await jsonRequest(server, "/v1/workspaces/alpha/panes/reorder", {
      method: "POST",
      body: JSON.stringify({ paneIds: ["00000000-0000-0000-0000-00000000000b"] })
    })
    expect(reordered.status).toBe(200)
    expect(await titles()).toEqual(["Terminal", "Chat", "Browser"])

    // A client drag sends one pane's new key; a reorder is not a content
    // change, so the pane's revision stays put.
    const panes = (await jsonRequest(server, "/v1/workspace-panes")).body as WorkspacePane[]
    const browser = panes[2]!
    const moved = await jsonRequest(server, `/v1/workspaces/alpha/panes/${browser.id}`, {
      method: "PATCH",
      body: JSON.stringify({ position: "0000000000018" })
    })
    expect(moved.body).toMatchObject({ position: "0000000000018", revision: browser.revision })
    expect(await titles()).toEqual(["Browser", "Terminal", "Chat"])
  })

  it("refuses to reorder a workspace that does not exist", async () => {
    const { server } = await start()
    const missing = await jsonRequest(server, "/v1/workspaces/missing/panes/reorder", {
      method: "POST",
      body: JSON.stringify({ paneIds: [] })
    })
    expect(missing.status).toBe(404)
  })
})
