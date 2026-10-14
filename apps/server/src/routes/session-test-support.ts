import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { expect } from "vitest"

import { jsonRequest, start, tempDirs } from "../test-support.js"

type StartedServer = Awaited<ReturnType<typeof start>>["server"]

export const setUpWorkspace = async () => {
  const { agents, server, services } = await start()
  const workspaceRoot = mkdtempSync(join(tmpdir(), "codevisor-server-workspace-"))
  tempDirs.push(workspaceRoot)
  const workspaceFolder = join(workspaceRoot, "codevisor")
  mkdirSync(workspaceFolder)
  const workspaceResponse = await jsonRequest(server, "/v1/projects", {
    body: JSON.stringify({ folderPath: workspaceFolder }),
    method: "POST"
  })
  expect(workspaceResponse.status).toBe(201)
  const workspace = workspaceResponse.body as { readonly id: string }
  return { agents, server, services, workspace, workspaceFolder, workspaceRoot }
}

export const createFirstSession = async (
  server: StartedServer,
  workspace: { readonly id: string }
) => {
  const sessionResponse = await jsonRequest(server, "/v1/sessions", {
    body: JSON.stringify({ projectId: workspace.id, harnessId: "codex", title: "First chat" }),
    method: "POST"
  })
  expect(sessionResponse.status).toBe(201)
  return sessionResponse.body as { readonly id: string; readonly agentSessionId: string }
}
