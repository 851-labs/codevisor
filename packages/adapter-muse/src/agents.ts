import { text, type MuseItem } from "./protocol.js"
import { output, parseArgs, textContent, toolStatus, type Edge, type MappedEvent } from "./rows.js"

export const subagentFinished = (item: MuseItem): boolean =>
  item.status !== "inProgress" ||
  ["resultReady", "closing", "closed"].includes(item.controlStatus ?? "")

const taskName = (agentPath: string | undefined): string | undefined =>
  agentPath
    ?.split("/")
    .filter((step) => step.trim() !== "" && !/^\d+$/.test(step))
    .slice(1)
    .at(-1)
    ?.trim()

const snippet = (objective: string): string => {
  const line = objective.trim().split("\n")[0]!.trim()
  if (line.length <= 60) return line
  const cut = line.slice(0, 60)
  const boundary = cut.lastIndexOf(" ")
  return `${(boundary > 20 ? cut.slice(0, boundary) : cut).trimEnd()}…`
}

const subagentName = (item: MuseItem): string | undefined =>
  (taskName(item.agentPath) ?? (item.objective ? snippet(item.objective) : undefined)) || undefined

export const subagentTitle = (item: MuseItem): string => {
  const name = subagentName(item)
  if (name) return `Agent: ${name}`
  return item.role ? `Agent (${item.role})` : "Agent"
}

export const MESSAGE_TOOLS = new Set(["subagent_send_message", "subagent_followup_task"])

interface AgentRun {
  readonly spawnId: string
  readonly taskId: string
  readonly name: string
  readonly path: string | undefined
  rowId: string
  turnId: string | null | undefined
  messagedIn: string | null | undefined
  runs: number
}

const meta = (run: AgentRun, continues = false) => ({
  _meta: {
    codevisorSubagent: {
      taskId: run.taskId,
      ...(continues ? { continues: true } : {})
    }
  }
})

export interface AgentRows {
  readonly subagent: (item: MuseItem, edge: Edge) => Array<MappedEvent>
  readonly message: (item: MuseItem, edge: Edge) => Array<MappedEvent>
  readonly runRow: (subagentItemId: string) => string
}

export const makeAgentRows = (scope: () => string, rows: Set<string>): AgentRows => {
  const runs: Array<AgentRun> = []
  const spawns = new Map<string, AgentRun>()
  const answered = new Set<string>()
  const addressed = (args: Record<string, unknown>): AgentRun | undefined => {
    const id = text(args.subagent_id)
    const path = text(args.agent_path)
    return (
      runs.find((run) => id !== undefined && run.taskId === `${scope()}:${id}`) ??
      runs.find((run) => path !== undefined && run.path === path) ??
      runs.find((run) => path !== undefined && run.name === taskName(path))
    )
  }

  const message = (item: MuseItem, edge: Edge): Array<MappedEvent> => {
    const args = parseArgs(item.args)
    const run = addressed(args)
    if (run === undefined) return []
    rows.add(item.itemId)
    if (edge === "started") {
      run.messagedIn = item.turnId
      const body = text(args.message) ?? text(args.task) ?? text(args.objective) ?? ""
      return [
        output({
          sessionUpdate: "tool_call",
          toolCallId: item.itemId,
          kind: "other",
          status: toolStatus(item.status),
          title: `Messaged agent: ${run.name}`,
          rawInput: { message: body },
          ...meta(run)
        })
      ]
    }
    if (item.status === "inProgress") return []
    const result = parseArgs(item.visibleOutput)
    const rejected = result.status === "rejected"
    const reason = text(result.reason)
    return [
      output({
        sessionUpdate: "tool_call_update",
        toolCallId: item.itemId,
        status: rejected ? "failed" : toolStatus(item.status),
        ...(rejected
          ? {
              content: textContent(`Not delivered${reason === undefined ? "" : ` (${reason})`}`)
            }
          : {})
      })
    ]
  }

  const start = (item: MuseItem): Array<MappedEvent> => {
    const objective = text(item.objective)
    let run: AgentRun | undefined
    if (item.subagentId !== undefined) {
      run = {
        spawnId: item.itemId,
        taskId: `${scope()}:${item.subagentId}`,
        name: subagentName(item) ?? item.role ?? "agent",
        path: item.agentPath,
        rowId: item.itemId,
        turnId: item.turnId,
        messagedIn: item.turnId,
        runs: 1
      }
      runs.push(run)
      spawns.set(item.itemId, run)
    }
    return [
      output({
        sessionUpdate: "tool_call",
        toolCallId: item.itemId,
        kind: "agent",
        status: "in_progress",
        title: subagentTitle(item),
        ...(objective === undefined ? {} : { rawInput: { prompt: objective } }),
        ...(run === undefined ? {} : meta(run))
      })
    ]
  }

  const reopen = (run: AgentRun | undefined, row: string): Array<MappedEvent> => {
    if (run === undefined || run.messagedIn === run.turnId)
      return [
        output({
          sessionUpdate: "tool_call_update",
          toolCallId: row,
          status: "in_progress"
        })
      ]
    run.runs += 1
    run.rowId = `${run.spawnId}:${run.runs}`
    run.turnId = run.messagedIn
    return [
      output({
        sessionUpdate: "tool_call",
        toolCallId: run.rowId,
        kind: "agent",
        status: "in_progress",
        title: `Agent: ${run.name}`,
        rawInput: {},
        ...meta(run, true)
      })
    ]
  }

  const subagent = (item: MuseItem, edge: Edge): Array<MappedEvent> => {
    if (edge === "started") return start(item)
    const run = spawns.get(item.itemId)
    const row = run?.rowId ?? item.itemId
    if (!subagentFinished(item)) return answered.delete(row) ? reopen(run, row) : []
    if (item.status === "inProgress" && answered.has(row)) return []
    answered.add(row)
    const result = text(item.result?.text) ?? text(item.result?.summary) ?? item.failureReason
    return [
      output({
        sessionUpdate: "tool_call_update",
        toolCallId: row,
        status: item.status === "inProgress" ? "completed" : toolStatus(item.status),
        content: textContent(result)
      })
    ]
  }

  return {
    subagent,
    message,
    runRow: (subagentItemId) => spawns.get(subagentItemId)?.rowId ?? subagentItemId
  }
}
