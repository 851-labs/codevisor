import type Database from "better-sqlite3"

import { isTurnEnd } from "./bot-conversation-attention.js"
import { jsonRecord, type JsonRecord } from "./event-payloads.js"
import { rowReader, text } from "./row-reader.js"
import type { SessionEventRow } from "./rows.js"

export const projectAgentCalls = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord
): void => {
  if (startsOrEndsTurn(event, payload)) return clearAgentCalls(sqlite, event.session_id)

  const toolCallId = toolCallIdOf(payload)
  if (toolCallId === undefined) return

  if (isSettled(payload)) return removeAgentCall(sqlite, event.session_id, toolCallId)
  if (talksToAgent(payload)) addAgentCall(sqlite, event.session_id, toolCallId)
}

export const clearAgentCalls = (sqlite: Database.Database, sessionId: string): void => {
  sqlite.prepare(agentCallSql.clear).run(sessionId)
}

const agentPath = /(?:^|\.)agents\.(?:start|message|answer|status|wait|debug\.\w+)$/

const agentCodeCall = /\bagents\.(?:start|message|answer|status|wait|debug\.\w+)\s*\(/

const settledStatuses = new Set(["completed", "failed", "cancelled"])

const startsOrEndsTurn = (event: SessionEventRow, payload: JsonRecord): boolean =>
  (event.kind === "session.updated" && payload.turnState === "started") || isTurnEnd(event, payload)

const toolCallIdOf = (payload: JsonRecord): string | undefined => {
  const isToolCall =
    payload.sessionUpdate === "tool_call" || payload.sessionUpdate === "tool_call_update"
  if (!isToolCall || typeof payload.toolCallId !== "string") return undefined
  return payload.toolCallId
}

const isSettled = (payload: JsonRecord): boolean =>
  typeof payload.status === "string" && settledStatuses.has(payload.status)

const talksToAgent = (payload: JsonRecord): boolean =>
  executionCallPaths(payload).some((path) => agentPath.test(path)) ||
  agentCodeCall.test(executedCode(payload))

const executionCallPaths = (payload: JsonRecord): ReadonlyArray<string> => {
  const calls = jsonRecord(jsonRecord(payload._meta)?.codevisorExecution)?.calls
  if (!Array.isArray(calls)) return []
  return calls.flatMap((call) => {
    const path = jsonRecord(call)?.path
    return typeof path === "string" ? [path] : []
  })
}

const executedCode = (payload: JsonRecord): string => {
  const code = jsonRecord(payload.rawInput)?.code
  return typeof code === "string" ? code : ""
}

const addAgentCall = (sqlite: Database.Database, sessionId: string, toolCallId: string): void => {
  const calls = agentCalls(sqlite, sessionId)
  if (calls === undefined || calls.includes(toolCallId)) return

  writeAgentCalls(sqlite, sessionId, [...calls, toolCallId])
}

const removeAgentCall = (
  sqlite: Database.Database,
  sessionId: string,
  toolCallId: string
): void => {
  const calls = agentCalls(sqlite, sessionId)
  if (calls === undefined || !calls.includes(toolCallId)) return

  writeAgentCalls(
    sqlite,
    sessionId,
    calls.filter((id) => id !== toolCallId)
  )
}

const agentCalls = (sqlite: Database.Database, sessionId: string): Array<string> | undefined => {
  const row = agentCallRows.maybe(sqlite.prepare(agentCallSql.read).get(sessionId))
  if (row === undefined) return undefined
  const parsed: unknown = JSON.parse(row.agent_calls)
  return Array.isArray(parsed) ? parsed.filter((id) => typeof id === "string") : []
}

const writeAgentCalls = (
  sqlite: Database.Database,
  sessionId: string,
  calls: ReadonlyArray<string>
): void => {
  sqlite.prepare(agentCallSql.write).run(JSON.stringify(calls), sessionId)
}

const agentCallRows = rowReader({ agent_calls: text })

const agentCallSql = {
  read: "select agent_calls from session_attention where session_id = ?",
  write: "update session_attention set agent_calls = ? where session_id = ?",
  clear:
    "update session_attention set agent_calls = '[]' where session_id = ? and agent_calls <> '[]'"
}
