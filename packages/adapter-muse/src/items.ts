import { diffStatsFromTexts } from "@codevisor/agent-runtime"

import { makeAgentRows, MESSAGE_TOOLS } from "./agents.js"
import { text, type MuseItem } from "./protocol.js"
import { output, parseArgs, textContent, toolStatus, type Edge, type MappedEvent } from "./rows.js"

export { subagentFinished, subagentTitle } from "./agents.js"
export type { MappedEvent } from "./rows.js"

/// Maps MSP's item stream (`item/started|updated|completed` carrying the
/// whole item, `item/delta` appending to one of its fields) onto Codevisor
/// transcript events.

/// Muse's built-in tools, as Codevisor's tool kinds.
export const museToolKind = (tool: string): string => {
  switch (tool) {
    case "read_file":
    case "read_skill":
    case "read_memory":
      return "read"
    case "write_file":
    case "edit_file":
    case "add_memory":
    case "edit_memory":
      return "edit"
    case "bash":
    case "bash_input":
    case "monitor":
      return "execute"
    case "search":
      return "search"
    case "web_fetch":
    case "web_search":
      return "fetch"
    default:
      return "other"
  }
}

/// Tool calls that only carry plumbing the transcript shows another way:
/// todos arrive as `session/todoListChanged`, questions as `userInput/request`,
/// and subagents as their own `subagent` items.
const hiddenTool = (tool: string): boolean =>
  tool === "write_todos" || tool === "request_user_input" || tool.startsWith("subagent_")

/// What the call acts on: the command, file, query or address.
export const museToolTitle = (tool: string, args: Record<string, unknown>): string =>
  text(args.description) ??
  text(args.command) ??
  text(args.path) ??
  text(args.pattern) ??
  text(args.query) ??
  text(args.url) ??
  tool

/// `bash` reports a JSON envelope once it settles; its output and exit code
/// are the parts worth showing.
const shellResult = (visible: string | undefined) => {
  if (visible === undefined || !visible.startsWith("{")) return { output: visible }
  const envelope = parseArgs(visible)
  return {
    output: typeof envelope.output === "string" ? envelope.output : visible,
    ...(typeof envelope.exit_code === "number" ? { exitCode: envelope.exit_code } : {})
  }
}

/// A write's or edit's diff, from the arguments the model wrote; Muse's own
/// counts (`patchSummary`) are authoritative for the stats.
const fileChange = (item: MuseItem, args: Record<string, unknown>) => {
  const path = text(args.path)
  if (path === undefined) return {}
  const summary = item.patchSummary
  const diffStats =
    summary === undefined ? undefined : [{ path, added: summary.added, removed: summary.removed }]
  if (item.tool === "write_file" && typeof args.content === "string") {
    return {
      content: [{ type: "diff", path, oldText: null, newText: args.content }],
      diffStats: diffStats ?? [diffStatsFromTexts(path, undefined, args.content)]
    }
  }
  if (
    item.tool === "edit_file" &&
    typeof args.find === "string" &&
    typeof args.replace === "string"
  )
    return {
      content: [{ type: "diff", path, oldText: args.find, newText: args.replace }],
      diffStats: diffStats ?? [diffStatsFromTexts(path, args.find, args.replace)]
    }
  return diffStats === undefined ? {} : { diffStats }
}

const OUTPUT_TAIL = 64 * 1024

/// Item kinds shown as tool-call rows.
const ROWS = new Set(["toolCall", "subagent", "webSearch", "skillRead", "compaction"])

export interface MuseItemMapper {
  readonly item: (item: MuseItem, edge: Edge) => Array<MappedEvent>
  /// The row a subagent's work streams under now: its spawn row, or the chip
  /// of the run a later turn's message started.
  readonly runRow: (subagentItemId: string) => string
  readonly delta: (itemId: string, field: string, delta: string) => Array<MappedEvent>
}

/// `scope` names the session the items belong to: subagent ids are only
/// unique within it.
export const makeMuseItemMapper = (scope: () => string = () => ""): MuseItemMapper => {
  const revisions = new Map<string, number>()
  /// Text already streamed per item, so a completed item only adds the rest.
  const streamed = new Map<string, string>()
  const outputs = new Map<string, string>()
  const thoughts = new Set<string>()
  /// Tool rows the transcript shows; output deltas for anything else drop.
  const tools = new Set<string>()
  const agents = makeAgentRows(scope, tools)
  const message = (item: MuseItem): Array<MappedEvent> => {
    const full = item.text ?? ""
    const seen = streamed.get(item.itemId) ?? ""
    if (!full.startsWith(seen) || full.length === seen.length) return []
    streamed.set(item.itemId, full)
    return [
      output({
        sessionUpdate: "agent_message_chunk",
        messageId: item.itemId,
        content: { type: "text", text: full.slice(seen.length) }
      })
    ]
  }

  const reasoning = (item: MuseItem): Array<MappedEvent> => {
    // Summaries stream as deltas; a reasoning item that never streamed
    // (resumed, or a provider without summaries) still shows its text.
    if (item.status === "inProgress" || thoughts.has(item.itemId)) return []
    thoughts.add(item.itemId)
    const full = item.summary?.join("\n\n") || item.text
    return full === undefined || full.length === 0
      ? []
      : [output({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: full } })]
  }

  const toolCall = (item: MuseItem, edge: Edge): Array<MappedEvent> => {
    const tool = item.tool ?? "tool"
    if (MESSAGE_TOOLS.has(tool)) return agents.message(item, edge)
    if (hiddenTool(tool)) return []
    tools.add(item.itemId)
    const args = parseArgs(item.args)
    const path = text(args.path)
    const common = {
      toolCallId: item.itemId,
      kind: museToolKind(tool),
      title: museToolTitle(tool, args),
      rawInput: args,
      ...(path === undefined ? {} : { locations: [{ path }] })
    }
    if (edge === "started")
      return [output({ sessionUpdate: "tool_call", status: toolStatus(item.status), ...common })]
    const settled = item.status !== "inProgress"
    if (!settled) {
      const summary = fileChange(item, args)
      return "diffStats" in summary
        ? [
            output({
              sessionUpdate: "tool_call_update",
              toolCallId: item.itemId,
              diffStats: summary.diffStats
            })
          ]
        : []
    }
    outputs.delete(item.itemId)
    const failed = item.status !== "completed"
    const shell =
      museToolKind(tool) === "execute"
        ? shellResult(item.visibleOutput)
        : { output: item.visibleOutput }
    const change = failed ? {} : fileChange(item, args)
    return [
      output({
        sessionUpdate: "tool_call_update",
        ...common,
        status: toolStatus(item.status),
        content: [
          ...textContent(failed ? (item.failureReason ?? shell.output) : shell.output),
          ...("content" in change ? change.content : [])
        ],
        ...("diffStats" in change ? { diffStats: change.diffStats } : {}),
        ...("exitCode" in shell ? { exitCode: shell.exitCode } : {}),
        rawOutput: item.visibleOutput ?? null
      })
    ]
  }

  /// A one-shot row for an action Muse reports as its own item kind.
  const action = (item: MuseItem, edge: Edge, kind: string, title: string): Array<MappedEvent> =>
    edge === "started"
      ? [
          output({
            sessionUpdate: "tool_call",
            toolCallId: item.itemId,
            kind,
            title,
            status: toolStatus(item.status)
          })
        ]
      : item.status === "inProgress"
        ? []
        : [
            output({
              sessionUpdate: "tool_call_update",
              toolCallId: item.itemId,
              kind,
              title,
              status: toolStatus(item.status)
            })
          ]

  const compaction = (item: MuseItem, edge: Edge): Array<MappedEvent> => {
    const status =
      edge === "started"
        ? "started"
        : item.status === "completed"
          ? "completed"
          : item.status === "inProgress"
            ? undefined
            : "failed"
    return status === undefined
      ? []
      : [output({ sessionUpdate: "context_compaction", compactionId: item.itemId, status })]
  }

  return {
    runRow: agents.runRow,
    item: (item, edge) => {
      // Replace-iff-higher: replays and re-issued frames are no-ops. A
      // completed item may arrive without its start (single-shot kinds).
      const previous = revisions.get(item.itemId)
      if (previous !== undefined && item.revision <= previous) return []
      revisions.set(item.itemId, item.revision)
      const events = (phase: Edge): Array<MappedEvent> => {
        switch (item.kind) {
          case "agentMessage":
            return message(item)
          case "reasoning":
            return reasoning(item)
          case "toolCall":
            return toolCall(item, phase)
          case "subagent":
            return agents.subagent(item, phase)
          case "webSearch":
            return action(item, phase, "fetch", text(item.query) ?? text(item.url) ?? "Web search")
          case "skillRead":
            return action(item, phase, "read", `Skill: ${item.selector ?? "skill"}`)
          case "compaction":
            return compaction(item, phase)
          default:
            // userMessage echoes the prompt; reminders, hooks and workflows
            // are Muse's own housekeeping.
            return []
        }
      }
      // A first sighting of a settled row opens it before settling it.
      return previous === undefined && edge !== "started" && ROWS.has(item.kind)
        ? [...events("started"), ...events(edge)]
        : events(edge)
    },
    delta: (itemId, field, delta) => {
      if (delta.length === 0) return []
      if (field === "text") {
        streamed.set(itemId, (streamed.get(itemId) ?? "") + delta)
        return [
          output({
            sessionUpdate: "agent_message_chunk",
            messageId: itemId,
            content: { type: "text", text: delta }
          })
        ]
      }
      if (field.startsWith("summary.")) {
        thoughts.add(itemId)
        return [
          output({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: delta } })
        ]
      }
      if (field === "output" && tools.has(itemId)) {
        // Each update carries the whole output so far; a long-running
        // command keeps its newest tail, as Muse's own view does.
        const accumulated = ((outputs.get(itemId) ?? "") + delta).slice(-OUTPUT_TAIL)
        outputs.set(itemId, accumulated)
        return [
          output({
            sessionUpdate: "tool_call_update",
            toolCallId: itemId,
            content: textContent(accumulated)
          })
        ]
      }
      return []
    }
  }
}
