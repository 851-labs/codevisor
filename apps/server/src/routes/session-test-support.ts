import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { decode } from "@codevisor/api"
import { makeDatabase, type CodevisorDatabaseService } from "@codevisor/db"
import { Schema } from "effect"
import { expect, onTestFinished } from "vitest"

import { jsonRequest, run, start, tempDirs } from "../test-support.js"
import { idOf } from "./response-test-support.js"
import type { attachSyncEventSocket } from "./sync-event-socket.js"

export const Identified = Schema.Struct({ id: Schema.String })

export const QueuedPrompt = Schema.Struct({ queueItemId: Schema.String })

export const CreatedSession = Schema.Struct({ id: Schema.String, agentSessionId: Schema.String })

const SentFrame = Schema.StructWithRest(
  Schema.Struct({
    id: Schema.Number,
    kind: Schema.String,
    previousEventId: Schema.optional(Schema.Number)
  }),
  [Schema.Record(Schema.String, Schema.Unknown)]
)

export type EventSink = Parameters<typeof attachSyncEventSocket>[3]

export const parseFrame = (raw: string) => {
  const value: unknown = JSON.parse(raw)
  return decode(SentFrame)(value)
}

export const memoryDatabase = async (
  overrides: Partial<CodevisorDatabaseService> = {}
): Promise<CodevisorDatabaseService> => {
  const db = await run(makeDatabase({ filename: ":memory:", serverId: "server" }))
  onTestFinished(() => run(db.close))
  return { ...db, ...overrides }
}

export type StartedServer = Awaited<ReturnType<typeof start>>["server"]

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
  const workspace = { id: idOf(workspaceResponse.body) }
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
  return decode(CreatedSession)(sessionResponse.body)
}
