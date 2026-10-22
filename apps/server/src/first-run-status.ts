import { FIRST_RUN_EVENT_SUBJECT, type FirstRunStatus } from "@codevisor/api"
import { FIRST_RUN_PROJECTS_PENDING, FIRST_RUN_PROJECTS_SETTING } from "@codevisor/db"

import {
  appendAndPublish,
  run,
  type CodevisorServerServices,
  type EventFanout
} from "./server-context.js"

export const publishFirstRunStatus = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  status: FirstRunStatus
): Promise<void> => {
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
): Promise<FirstRunStatus> =>
  latest.get(services) ??
  statusFromMarker(await run(services.db.getMachineSetting(FIRST_RUN_PROJECTS_SETTING)))

const latest = new WeakMap<CodevisorServerServices, FirstRunStatus>()

const statusFromMarker = (marker: string | undefined): FirstRunStatus => {
  if (marker === undefined) return { state: "notApplicable" }
  if (marker === FIRST_RUN_PROJECTS_PENDING) return { state: "running" }
  return { state: "done" }
}
