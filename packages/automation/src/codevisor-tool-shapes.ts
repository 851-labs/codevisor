import type { CodevisorApiToolSpec } from "./codevisor-api-tool-spec.js"
import { isPlainRecord, type UnknownRecord } from "./unknown-values.js"

export const shapedToolResult = (spec: CodevisorApiToolSpec, body: unknown): unknown => {
  const idName = recordIdName(spec.path)
  const listed = listShape(spec.path, body)
  if (listed !== undefined) {
    return { ...listed, items: listed.items.map((item) => namedRecord(item, idName)) }
  }
  return namedRecord(body, idName)
}

export const namedRecord = (value: unknown, idName: string | undefined): unknown => {
  if (!isPlainRecord(value)) return agentNamed(value)
  return Object.fromEntries(
    Object.entries(value).map(([key, field]) => [fieldName(key, idName), agentNamed(field)])
  )
}

const agentNamed = (value: unknown): unknown => {
  if (Array.isArray(value)) return value.map(agentNamed)
  if (!isPlainRecord(value)) return value
  return Object.fromEntries(
    Object.entries(value).map(([key, field]) => [agentFieldNames[key] ?? key, agentNamed(field)])
  )
}

export const recordIdName = (path: string): string | undefined => {
  const resource = lastLiteralSegment(path)
  return resource === undefined ? undefined : recordIdNames[resource]
}

const fieldName = (key: string, idName: string | undefined): string => {
  if (key === "id") return idName ?? key
  return agentFieldNames[key] ?? key
}

const agentFieldNames: Readonly<Record<string, string>> = {
  sessionId: "agentId",
  parentSessionId: "parentAgentId",
  targetSessionId: "agentId"
}

const recordIdNames: Readonly<Record<string, string>> = {
  accounts: "accountId",
  agents: "agentId",
  bots: "botId",
  clients: "clientId",
  files: "fileId",
  harnesses: "harnessId",
  jobs: "jobId",
  machines: "machineId",
  mcps: "mcpId",
  panes: "paneId",
  plugins: "pluginId",
  projects: "projectId",
  queue: "queueId",
  removals: "removalId",
  sessions: "agentId",
  subscriptions: "subscriptionId",
  "workspace-panes": "paneId",
  workspaces: "workspaceId",
  worktrees: "worktreeId"
}

const lastLiteralSegment = (path: string): string | undefined =>
  path.split("/").findLast((segment) => segment.length > 0 && !segment.startsWith(":"))

interface ListShape extends UnknownRecord {
  readonly items: ReadonlyArray<unknown>
}

const listShape = (path: string, body: unknown): ListShape | undefined => {
  if (Array.isArray(body)) return { items: body }
  if (!isPlainRecord(body)) return undefined
  const key = lastLiteralSegment(path)
  const items = key === undefined ? undefined : body[key]
  if (key === undefined || !Array.isArray(items)) return undefined
  return { ...withoutKey(body, key), items }
}

const withoutKey = (record: UnknownRecord, key: string): UnknownRecord =>
  Object.fromEntries(Object.entries(record).filter(([name]) => name !== key))
