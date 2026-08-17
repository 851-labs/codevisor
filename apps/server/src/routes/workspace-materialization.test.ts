import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { jsonRequest, run, start, tempDirs } from "../test-support.js"

describe("workspace materialization", () => {
  it("materializes native workspace identities when sessions assign them", async () => {
    const { server, services } = await start()
    const root = mkdtempSync(join(tmpdir(), "codevisor-server-native-workspaces-"))
    tempDirs.push(root)
    const projectFolder = join(root, "project")
    mkdirSync(projectFolder)
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: projectFolder }),
        method: "POST"
      })
    ).body as { readonly id: string; readonly name: string }

    const created = await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({
        id: "native-chat",
        projectId: project.id,
        harnessId: "codex",
        workspaceId: "native-workspace"
      }),
      method: "POST"
    })
    expect(created.status).toBe(201)
    expect(created.body).toMatchObject({
      id: "native-chat",
      workspaceId: "native-workspace"
    })

    const detached = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          id: "detached-chat",
          projectId: project.id,
          harnessId: "codex"
        }),
        method: "POST"
      })
    ).body as { readonly id: string }
    const assigned = await jsonRequest(server, `/v1/sessions/${detached.id}`, {
      body: JSON.stringify({ workspaceId: "patched-workspace" }),
      method: "PATCH"
    })
    expect(assigned.status).toBe(200)
    expect(assigned.body).toMatchObject({ workspaceId: "patched-workspace" })

    const otherProjectFolder = join(root, "other-project")
    mkdirSync(otherProjectFolder)
    const otherProject = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: otherProjectFolder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    expect(
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          id: "conflicting-workspace-chat",
          projectId: otherProject.id,
          harnessId: "codex",
          workspaceId: "native-workspace"
        }),
        method: "POST"
      })
    ).toEqual({
      status: 409,
      body: {
        error: `Workspace native-workspace belongs to project ${project.id}, not ${otherProject.id}`
      }
    })

    expect((await jsonRequest(server, "/v1/workspaces")).body).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: "native-workspace",
          projectId: project.id,
          name: project.name,
          rootDirectory: projectFolder
        }),
        expect.objectContaining({
          id: "patched-workspace",
          projectId: project.id,
          name: project.name,
          rootDirectory: projectFolder
        })
      ])
    )
    expect(await run(services.db.listEvents(0))).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ kind: "workspace.updated", subjectId: "native-workspace" }),
        expect.objectContaining({ kind: "workspace.updated", subjectId: "patched-workspace" })
      ])
    )
  })
})
