import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { expect } from "vitest"
import { jsonRequest, start, tempDirs } from "../test-support.js"

type StartedServer = Awaited<ReturnType<typeof start>>["server"]

/// A started server with one registered (and renamed) project so the global
/// event stream opens with project.created then project.updated.
export const setUpWorkspace = async () => {
  const { agents, server, services } = await start()
  const workspaceRoot = mkdtempSync(join(tmpdir(), "codevisor-server-workspace-"))
  tempDirs.push(workspaceRoot)
  const workspaceFolder = join(workspaceRoot, "codevisor")
  mkdirSync(workspaceFolder)
  const workspaceResponse = await jsonRequest(server, "/v1/projects", {
    body: JSON.stringify({ folderPath: workspaceFolder, id: "workspace-client-id" }),
    method: "POST"
  })
  expect(workspaceResponse.status).toBe(201)
  const workspace = workspaceResponse.body as { readonly id: string }
  expect(workspace.id).toBe("workspace-client-id")
  expect(
    (
      await jsonRequest(server, `/v1/projects/${workspace.id}`, {
        body: JSON.stringify({ name: "Renamed" }),
        method: "PATCH"
      })
    ).body
  ).toMatchObject({ name: "Renamed" })
  return { agents, server, services, workspace, workspaceFolder, workspaceRoot }
}

/// The scenario's first codex chat, whose agent session the fake runtime
/// names deterministically.
export const createFirstSession = async (
  server: StartedServer,
  workspace: { readonly id: string }
) => {
  const sessionResponse = await jsonRequest(server, "/v1/sessions", {
    body: JSON.stringify({ projectId: workspace.id, harnessId: "codex", title: "First chat" }),
    method: "POST"
  })
  const session = sessionResponse.body as { readonly id: string; readonly agentSessionId: string }
  expect(session.agentSessionId).toBe("agent-codex-codevisor")
  return session
}
