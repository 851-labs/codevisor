import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { decode, Project } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { jsonRequest, start, tempDirs, listEvents } from "../test-support.js"
import { idOf } from "./response-test-support.js"

describe("workspace materialization", () => {
  it("materializes native workspace identities when sessions assign them", async () => {
    const { server, services } = await start()
    const root = mkdtempSync(join(tmpdir(), "codevisor-server-native-workspaces-"))
    tempDirs.push(root)
    const projectFolder = join(root, "project")
    mkdirSync(projectFolder)
    const project = decode(Project)(
      (
        await jsonRequest(server, "/v1/projects", {
          body: JSON.stringify({ folderPath: projectFolder }),
          method: "POST"
        })
      ).body
    )

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

    const detachedId = idOf(
      (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            id: "detached-chat",
            projectId: project.id,
            harnessId: "codex"
          }),
          method: "POST"
        })
      ).body
    )
    const assigned = await jsonRequest(server, `/v1/sessions/${detachedId}`, {
      body: JSON.stringify({ workspaceId: "patched-workspace" }),
      method: "PATCH"
    })
    expect(assigned.status).toBe(200)
    expect(assigned.body).toMatchObject({ workspaceId: "patched-workspace" })

    const otherProjectFolder = join(root, "other-project")
    mkdirSync(otherProjectFolder)
    const otherProjectId = idOf(
      (
        await jsonRequest(server, "/v1/projects", {
          body: JSON.stringify({ folderPath: otherProjectFolder }),
          method: "POST"
        })
      ).body
    )
    expect(
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          id: "conflicting-workspace-chat",
          projectId: otherProjectId,
          harnessId: "codex",
          workspaceId: "native-workspace"
        }),
        method: "POST"
      })
    ).toEqual({
      status: 409,
      body: {
        error: `Workspace native-workspace belongs to project ${project.id}, not ${otherProjectId}`
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
    expect(listEvents(services)).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ kind: "workspace.updated", subjectId: "native-workspace" }),
        expect.objectContaining({ kind: "workspace.updated", subjectId: "patched-workspace" })
      ])
    )
  })
})
