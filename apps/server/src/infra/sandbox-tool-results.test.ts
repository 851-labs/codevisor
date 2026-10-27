import { describe, expect, it } from "vitest"

import { sandboxHarness } from "./sandbox-test-support.js"

const request = { profileId: "profile-1", projectId: "project-1", name: "Spike box" }

describe("sandboxes on newer servers", () => {
  it("understands normalized tool results: named ids and item lists", async () => {
    const harness = await sandboxHarness()
    harness.controls.answer = (tool) => {
      if (tool === "codevisor.projects.clone") return { projectId: "remote-normalized" }
      if (tool !== "codevisor.workspaces.list") return undefined
      return {
        items: [
          "noise",
          ...harness.workspaces.map(({ id, isArchived }) => ({ workspaceId: id, isArchived }))
        ]
      }
    }

    await harness.machines.create(request)
    await harness.machines.settled()
    await harness.machines.watch()

    expect((await harness.machines.list())[0]).toMatchObject({
      state: "ready",
      remoteProjectId: "remote-normalized"
    })

    const workspace = harness.workspaces[0]
    if (workspace !== undefined) workspace.isArchived = true
    await harness.machines.watch()

    expect((await harness.machines.list()).map((machine) => machine.state)).toEqual(["archived"])
  })
})
