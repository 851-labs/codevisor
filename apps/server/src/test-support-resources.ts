import { rmSync } from "node:fs"

import type { CodevisorDatabaseService } from "@codevisor/db"
import type { makeMcpManager } from "@codevisor/mcp"
import { Effect } from "effect"
import { vi } from "vitest"

import type { RunningCodevisorServer } from "./server.js"

export const tempDirs: Array<string> = []
export const runningServers: Array<RunningCodevisorServer> = []
export const databases: Array<CodevisorDatabaseService> = []
export const mcpManagers: Array<ReturnType<typeof makeMcpManager>> = []

export const blockExternalFetch = (): void => {
  vi.stubGlobal("fetch", localFetch)
}

export const closeTestResources = async (): Promise<void> => {
  const failures = [
    ...(await closeServers()),
    ...(await closeEach(mcpManagers, (mcp) => mcp.close())),
    ...(await closeEach(databases, (database) => Effect.runPromise(database.close))),
    ...(await closeEach(tempDirs, (dir) => rmSync(dir, { force: true, recursive: true }))),
    ...(await attempt(() => vi.unstubAllGlobals()))
  ]
  if (failures.length > 0) throw new AggregateError(failures, "Cleaning up test resources failed")
}

const realFetch = globalThis.fetch
const localHosts = new Set(["127.0.0.1", "localhost", "[::1]"])

const localFetch = (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
  const url = new URL(input instanceof Request ? input.url : input)
  if (!localHosts.has(url.hostname)) {
    return Promise.reject(new TypeError("External upstream unavailable in this fixture"))
  }
  const headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : {}))
  headers.set("Connection", "close")
  return realFetch(input, { ...init, headers })
}

const closeServers = async (): Promise<Array<unknown>> => {
  const closed = await Promise.allSettled(
    runningServers.splice(0).map((server) => Effect.runPromise(server.close))
  )
  return closed.flatMap((result) => (result.status === "rejected" ? [result.reason] : []))
}

const closeEach = async <A>(
  resources: Array<A>,
  close: (resource: A) => unknown
): Promise<Array<unknown>> => {
  const failures: Array<unknown> = []
  for (const resource of resources.splice(0))
    failures.push(...(await attempt(() => close(resource))))
  return failures
}

const attempt = async (step: () => unknown): Promise<Array<unknown>> => {
  try {
    await step()
    return []
  } catch (cause) {
    return [cause]
  }
}
