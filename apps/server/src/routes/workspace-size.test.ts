import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { WorkspaceSize } from "@codevisor/api"
import { Schema } from "effect"
import { afterEach, describe, expect, it } from "vitest"

import { jsonRequest, makeServices, run, startWithApp } from "../test-support.js"

const roots: Array<string> = []

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

const checkoutWithFile = (bytes: number): string => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-workspace-size-"))
  roots.push(root)
  writeFileSync(join(root, "data.bin"), Buffer.alloc(bytes, 1))
  return root
}

const fixture = async () => {
  const { services } = await makeServices("workspace-size")
  const project = await run(services.db.createProject({ folderPath: "/tmp/workspace-size" }))
  const workspace = (fields: { rootDirectory?: string; isArchived?: boolean }) =>
    run(
      services.db.upsertWorkspace({
        projectId: project.id,
        name: "Work",
        hasCustomName: false,
        ...fields
      })
    )
  const server = await startWithApp(services)
  const size = async (workspaceId: string) =>
    Schema.decodeUnknownSync(WorkspaceSize)(
      (await jsonRequest(server, `/v1/workspaces/${workspaceId}/size`)).body
    )
  return { server, workspace, size }
}

describe("workspace size", () => {
  it("reports the disk space the checkout folder takes", async () => {
    const f = await fixture()
    const work = await f.workspace({ rootDirectory: checkoutWithFile(256 * 1024) })

    const { bytes } = await f.size(work.id)

    expect(bytes).toBeGreaterThanOrEqual(256 * 1024)
  })

  it("reports no size without a checkout on disk", async () => {
    const f = await fixture()
    const archived = await f.workspace({ rootDirectory: checkoutWithFile(1), isArchived: true })
    const missing = await f.workspace({ rootDirectory: "/nonexistent/codevisor-checkout" })

    expect(await f.size(archived.id)).toEqual({})
    expect(await f.size(missing.id)).toEqual({})
    expect((await jsonRequest(f.server, "/v1/workspaces/unknown/size")).status).toBe(404)
  })
})
