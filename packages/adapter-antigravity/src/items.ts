import { diffStatsFromTexts } from "@codevisor/agent-runtime"
import type { EventKind } from "@codevisor/api"

import { param, record, text, type AgyStep } from "./protocol.js"

/// Maps agy's step stream onto Codevisor transcript events. A step is sent
/// as it starts (`ACTIVE`) and again as it settles (`DONE`/`ERROR`) under
/// the same index; text arrives as `text_delta` fragments of one step.

export interface MappedEvent {
  readonly kind: EventKind
  readonly payload: Record<string, unknown>
}

const output = (payload: Record<string, unknown>): MappedEvent => ({
  kind: "session.output",
  payload
})

const textContent = (value: string | undefined) =>
  value === undefined ? [] : [{ type: "content", content: { type: "text", text: value } }]

/// agy's built-in tools, as Codevisor's tool kinds.
export const agyToolKind = (tool: string): string => {
  switch (tool) {
    case "view_file":
    case "view_file_outline":
    case "view_code_item":
    case "list_dir":
      return "read"
    case "write_to_file":
    case "replace_file_content":
    case "multi_replace_file_content":
      return "edit"
    case "run_command":
    case "send_command_input":
    case "command_status":
      return "execute"
    case "grep_search":
    case "find_by_name":
    case "codebase_search":
      return "search"
    case "read_url_content":
    case "search_web":
      return "fetch"
    default:
      return "other"
  }
}

/// What the call acts on: the command, file, query or address, else agy's
/// own one-line summary of it.
export const agyToolTitle = (tool: string, parameters: Record<string, unknown>): string =>
  text(param(parameters, "CommandLine", "Command")) ??
  text(param(parameters, "TargetFile", "AbsolutePath", "FilePath", "DirectoryPath")) ??
  text(param(parameters, "Query", "Pattern", "SearchPath")) ??
  text(param(parameters, "Url")) ??
  text(param(parameters, "toolSummary", "toolAction")) ??
  tool

const EDIT_TOOLS = new Set(["write_to_file", "replace_file_content", "multi_replace_file_content"])

/// An edit's diff, rebuilt from what the model wrote: agy reports no diff of
/// its own. `write_to_file` carries the whole file; the replace tools carry
/// one chunk inline or a `ReplacementChunks` list.
const fileChange = (tool: string, parameters: Record<string, unknown>) => {
  const path = text(param(parameters, "TargetFile", "AbsolutePath"))
  if (path === undefined || !EDIT_TOOLS.has(tool)) return undefined
  const whole = param(parameters, "CodeContent")
  if (typeof whole === "string")
    return {
      content: [{ type: "diff", path, oldText: null, newText: whole }],
      diffStats: [diffStatsFromTexts(path, undefined, whole)]
    }
  const listed = param(parameters, "ReplacementChunks")
  const chunks = (Array.isArray(listed) ? listed : [parameters]).flatMap((entry) => {
    const chunk = record(entry)
    const newText = param(chunk, "ReplacementContent")
    if (typeof newText !== "string") return []
    const oldText = param(chunk, "TargetContent")
    return [{ oldText: typeof oldText === "string" ? oldText : null, newText }]
  })
  if (chunks.length === 0) return undefined
  const stats = chunks.map((chunk) => diffStatsFromTexts(path, chunk.oldText, chunk.newText))
  return {
    content: chunks.map((chunk) => ({ type: "diff", path, ...chunk })),
    diffStats: [
      {
        path,
        added: stats.reduce((sum, stat) => sum + stat.added, 0),
        removed: stats.reduce((sum, stat) => sum + stat.removed, 0)
      }
    ]
  }
}

/// A subagent prompt's first line, cut at a word boundary.
const snippet = (prompt: string): string => {
  const line = prompt.trim().split("\n")[0]!.trim()
  if (line.length <= 60) return line
  const cut = line.slice(0, 60)
  const boundary = cut.lastIndexOf(" ")
  return `${(boundary > 20 ? cut.slice(0, boundary) : cut).trimEnd()}…`
}

/// `invoke_subagent` runs one or more subagents; the row is named for the
/// first, as Claude and Codex title theirs.
const subagentRow = (parameters: Record<string, unknown>) => {
  const listed = param(parameters, "Subagents")
  const prompts = (Array.isArray(listed) ? listed : [parameters]).flatMap((entry) => {
    const prompt = text(param(record(entry), "Prompt", "Task"))
    return prompt === undefined ? [] : [prompt]
  })
  const first = prompts[0]
  return {
    title:
      first === undefined
        ? "Agent"
        : `Agent: ${snippet(first)}${prompts.length > 1 ? ` (+${prompts.length - 1} more)` : ""}`,
    rawInput: first === undefined ? {} : { prompt: prompts.join("\n\n") }
  }
}

/// agy runs every MCP tool through `call_mcp_tool`; titled `server.tool`
/// as Codex titles its MCP calls, with the tool's own arguments as input.
const mcpCall = (parameters: Record<string, unknown>) => {
  const server = text(param(parameters, "ServerName"))
  const tool = text(param(parameters, "ToolName"))
  return server === undefined || tool === undefined
    ? undefined
    : { title: `${server}.${tool}`, rawInput: record(param(parameters, "Arguments")) }
}

/// agy keeps each MCP tool's schema as a file in its data root and reads it
/// before a call: plumbing, not the agent's work.
const schemaRead = (name: string, path: string | undefined): boolean =>
  name === "view_file" && path !== undefined && /\/antigravity-cli\/mcp\//.test(path)

const settledStatus = (state: string): string => (state === "DONE" ? "completed" : "failed")

export interface AgyStepMapper {
  readonly step: (step: AgyStep) => Array<MappedEvent>
}

/// `scope` names the conversation the steps belong to: indexes are only
/// unique within it.
export const makeAgyStepMapper = (scope: () => string): AgyStepMapper => {
  /// Tool rows opened so far, and those already settled.
  const opened = new Set<string>()
  const settled = new Set<string>()

  const tool = (step: AgyStep, id: string): Array<MappedEvent> => {
    if (settled.has(id)) return []
    const name = step.tool_info?.name ?? step.tool_name ?? "tool"
    const parameters = record(step.tool_info?.parameters)
    const agent = name === "invoke_subagent" ? subagentRow(parameters) : undefined
    const mcp = name === "call_mcp_tool" ? mcpCall(parameters) : undefined
    const path = text(param(parameters, "TargetFile", "AbsolutePath", "FilePath"))
    if (schemaRead(name, path)) return []
    const common = {
      toolCallId: id,
      kind: agent === undefined ? agyToolKind(name) : "agent",
      title: agent?.title ?? mcp?.title ?? agyToolTitle(name, parameters),
      rawInput: agent?.rawInput ?? mcp?.rawInput ?? parameters,
      ...(path === undefined ? {} : { locations: [{ path }] }),
      ...(agent === undefined ? {} : { _meta: { codevisorSubagent: { taskId: id } } })
    }
    const events: Array<MappedEvent> = []
    if (!opened.has(id)) {
      opened.add(id)
      events.push(output({ sessionUpdate: "tool_call", status: "in_progress", ...common }))
    }
    if (step.state === "ACTIVE") return events
    settled.add(id)
    const failed = step.state !== "DONE"
    const change = failed ? undefined : fileChange(name, parameters)
    const error = text(step.tool_info?.error?.message)
    const result = text(step.tool_info?.output)
    events.push(
      output({
        sessionUpdate: "tool_call_update",
        ...common,
        status: settledStatus(step.state),
        content: [...textContent(failed ? (error ?? result) : result), ...(change?.content ?? [])],
        ...(change === undefined ? {} : { diffStats: change.diffStats }),
        rawOutput: step.tool_info?.output ?? null
      })
    )
    return events
  }

  return {
    step: (step) => {
      // A subagent's own steps report on its conversation; its row in the
      // parent carries its result.
      const conversation = step.conversation_id
      if (conversation !== undefined && scope() !== "" && conversation !== scope()) return []
      const id = `${conversation ?? scope()}:${step.step_index}`
      const events: Array<MappedEvent> = []
      switch (step.step_type) {
        case "agent_response":
          if (typeof step.text_delta === "string" && step.text_delta.length > 0)
            events.push(
              output({
                sessionUpdate: "agent_message_chunk",
                messageId: id,
                content: { type: "text", text: step.text_delta }
              })
            )
          break
        case "tool":
        case "tool_call":
          events.push(...tool(step, id))
          break
        default:
        // The prompt's echo (`user_input`) and checkpoints only carry usage.
      }
      const total = step.usage?.total_tokens
      // The latest model call's prompt plus reply: what the context holds.
      if (typeof total === "number" && total > 0)
        events.push({
          kind: "session.updated",
          payload: { sessionUpdate: "usage_update", used: total }
        })
      return events
    }
  }
}
