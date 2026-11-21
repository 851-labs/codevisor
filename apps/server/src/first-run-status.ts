import { FIRST_RUN_EVENT_SUBJECT, type FirstRunStatus } from "@codevisor/api"
import { FIRST_RUN_PROJECTS_PENDING, FIRST_RUN_PROJECTS_SETTING } from "@codevisor/db"

import { readClaudeCodeLoginQuestion } from "./first-run-claude-login.js"
import { foldersToAsk, readPendingFolders } from "./first-run-folders.js"
import {
  appendAndPublish,
  run,
  type CodevisorServerServices,
  type EventFanout
} from "./server-context.js"

export const publishFirstRunStatus = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  progress: FirstRunStatus
): Promise<void> => {
  const status = await withQuestions(services, progress)
  latest.set(services, status)
  await appendAndPublish(services.db, fanout, "firstRun.updated", FIRST_RUN_EVENT_SUBJECT, status)
}

export const failedFirstRunStatus = (services: CodevisorServerServices): FirstRunStatus => {
  const harnesses = latest.get(services)?.harnesses
  if (harnesses === undefined) return { state: "failed" }
  return { state: "failed", harnesses }
}

export const readFirstRunStatus = async (
  services: CodevisorServerServices
): Promise<FirstRunStatus> => {
  const published = latest.get(services)
  if (published !== undefined) return published

  const marker = await run(services.db.getMachineSetting(FIRST_RUN_PROJECTS_SETTING))
  return withQuestions(services, statusFromMarker(marker))
}

const latest = new WeakMap<CodevisorServerServices, FirstRunStatus>()

const withQuestions = async (
  services: CodevisorServerServices,
  status: FirstRunStatus
): Promise<FirstRunStatus> => {
  const folders = foldersToAsk(await readPendingFolders(services))
  const claudeCodeLogin = await readClaudeCodeLoginQuestion(services)
  return {
    ...progressOf(status),
    ...(folders.length === 0 ? {} : { folders }),
    ...(claudeCodeLogin === undefined ? {} : { claudeCodeLogin })
  }
}

const progressOf = (status: FirstRunStatus): FirstRunStatus => ({
  state: status.state,
  ...(status.harnesses === undefined ? {} : { harnesses: status.harnesses }),
  ...(status.projects === undefined ? {} : { projects: status.projects })
})

const statusFromMarker = (marker: string | undefined): FirstRunStatus => {
  if (marker === undefined) return { state: "notApplicable" }
  if (marker === FIRST_RUN_PROJECTS_PENDING) return { state: "running" }
  return { state: "done" }
}
