import type { SessionConfigOption, SetConfigRequest } from "@codevisor/api"

import type { CodevisorServerServices, EventFanout } from "../server-context.js"
import { run } from "../server-context.js"
import { configSelectionsFromOptions, ensureAgentSessionFor } from "./session-workspace.js"

export interface SessionConfigPickResult {
  readonly configId: string
  readonly configOptions: ReadonlyArray<SessionConfigOption>
}

/// Applies one picker change. With a live runtime the harness answers with
/// the resulting option list (a model change can replace the effort and
/// speed lists). Without one, the choice is only recorded: launching a
/// harness process just to tell it a preference is what made the composer
/// pickers hang, and the next connect or prompt restores saved selections
/// against the live list anyway — which is also where an unavailable value
/// gets reported.
export const applySessionConfigPick = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  payload: SetConfigRequest
): Promise<SessionConfigPickResult> => {
  const { agentSessionId } = await run(services.db.getSessionSummary(sessionId))
  const isRuntimeLoaded =
    agentSessionId !== undefined &&
    agentSessionId !== "" &&
    services.agents.loadedAgentSessionIds().includes(agentSessionId)
  if (!isRuntimeLoaded) {
    const saved = await run(services.db.getSessionConfigSelections(sessionId))
    await run(
      services.db.replaceSessionConfigSelections(sessionId, {
        ...saved,
        [payload.configId]: payload.value
      })
    )
    const runtime = await run(services.db.getSessionRuntimeState(sessionId))
    const configOptions = persistedConfigOptions(runtime).map((option) =>
      option.id === payload.configId ? { ...option, currentValue: payload.value } : option
    )
    return { configId: payload.configId, configOptions }
  }
  const agentSession = await ensureAgentSessionFor(services, fanout, serverId, sessionId)
  const configOptions = await run(
    services.agents.setConfigOption(agentSession.sessionId, payload.configId, payload.value)
  )
  await run(
    services.db.replaceSessionConfigSelections(
      sessionId,
      configSelectionsFromOptions(configOptions)
    )
  )
  return { configId: payload.configId, configOptions }
}

/// The last option snapshot a runtime published for this chat. A pick
/// recorded while no runtime is up is reflected onto it so the client gets
/// an answer shaped like a live one. The store always answers with an
/// object whose `configOptions` is an array (empty when nothing was
/// published), so the untyped value is read as that shape.
const persistedConfigOptions = (runtime: unknown): ReadonlyArray<SessionConfigOption> =>
  (runtime as { readonly configOptions: ReadonlyArray<SessionConfigOption> }).configOptions
