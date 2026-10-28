import { withRunningThoughtLevel } from "@codevisor/agent-runtime"
import type { AgentCallerDefaults, AgentProjectSource, SessionSummary } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"

import { isRecord } from "./mcp-guards.js"
import { run } from "./mcp-support.js"

const remoteAgentStartPath = "codevisor.agents.start"

export const withCallerDefaults = async (
  db: CodevisorDatabaseService,
  sessionId: string,
  path: string,
  args: unknown
): Promise<unknown> => {
  if (path !== remoteAgentStartPath || !isRecord(args) || "callerDefaults" in args) return args
  const caller = await run(db.getSessionSummary(sessionId)).catch(() => undefined)
  if (caller === undefined) return args

  return { ...args, callerDefaults: await callerDefaults(db, caller, args["project"]) }
}

const callerDefaults = async (
  db: CodevisorDatabaseService,
  caller: SessionSummary,
  wantedProject: unknown
): Promise<AgentCallerDefaults> => {
  const runtime = await run(db.getSessionRuntimeState(caller.id))
  const configSelections = withRunningThoughtLevel(caller.configSelections, runtime)
  const project = await projectSource(db, projectKey(caller, wantedProject))
  return {
    harness: caller.harnessId,
    ...(configSelections === undefined ? {} : { configSelections }),
    ...(project === undefined ? {} : { project })
  }
}

const projectKey = (caller: SessionSummary, wantedProject: unknown): string =>
  (typeof wantedProject === "string" ? wantedProject : caller.projectId).toLowerCase()

const projectSource = async (
  db: CodevisorDatabaseService,
  key: string
): Promise<AgentProjectSource | undefined> => {
  const projects = await run(db.listProjects)
  const project = projects.find(
    (candidate) => candidate.id.toLowerCase() === key || candidate.name.toLowerCase() === key
  )
  if (project?.repoUrl === undefined) return undefined
  return { name: project.name, repoUrl: project.repoUrl }
}
