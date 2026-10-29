import {
  BOT_GOAL_REFUSAL,
  BOT_PLAN_MODE_REFUSAL,
  isPlanModeId,
  type CreateSessionOptions
} from "@codevisor/agent-runtime"
import type { Project, SessionConfigOption, SetConfigRequest } from "@codevisor/api"

import {
  getProjectOrFail,
  HttpFailure,
  run,
  type CodevisorServerServices
} from "../server-context.js"
import { isBotProject } from "./project-probe.js"
import { persistedConfigOptions } from "./session-config-publish.js"

export const withBotSessionOption = (
  project: Project,
  options: CreateSessionOptions | undefined
): CreateSessionOptions | undefined => {
  if (!isBotProject(project)) return options
  return { ...options, bot: true }
}

export const refuseGoalForBot = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<void> => {
  if (await isBotSession(services, sessionId)) throw new HttpFailure(409, BOT_GOAL_REFUSAL)
}

export const refusePlanModeForBot = async (
  services: CodevisorServerServices,
  sessionId: string,
  modeId: string
): Promise<void> => {
  if (!isPlanModeId(modeId)) return
  if (await isBotSession(services, sessionId)) throw new HttpFailure(409, BOT_PLAN_MODE_REFUSAL)
}

export const refusePlanConfigForBot = async (
  services: CodevisorServerServices,
  sessionId: string,
  pick: SetConfigRequest
): Promise<void> => {
  if (!isPlanModeId(pick.value)) return
  if (!(await isBotSession(services, sessionId))) return

  const options = persistedConfigOptions(await run(services.db.getSessionRuntimeState(sessionId)))
  if (picksMode(pick.configId, options)) throw new HttpFailure(409, BOT_PLAN_MODE_REFUSAL)
}

const isBotSession = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<boolean> => {
  const session = await run(services.db.getSessionSummary(sessionId))
  return isBotProject(await getProjectOrFail(services.db, session.projectId))
}

const picksMode = (configId: string, options: ReadonlyArray<SessionConfigOption>): boolean =>
  configId === "mode" ||
  options.some((option) => option.id === configId && option.category === "mode")
