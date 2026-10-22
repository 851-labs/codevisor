import {
  run,
  swallowError,
  type CodevisorServerServices,
  type RouteState
} from "../server-context.js"

export const sessionHarnessId = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<string | undefined> =>
  (await run(services.db.getSessionSummary(sessionId)).catch(swallowError))?.harnessId

export const pausedForUpdate = async (
  services: CodevisorServerServices,
  routeState: RouteState,
  sessionId: string
): Promise<boolean> => {
  if (!routeState.restart.isActive()) return false

  return routeState.restart.gates(await sessionHarnessId(services, sessionId))
}
