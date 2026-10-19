import { placeConfigValue } from "@codevisor/agent-runtime"
import { decode, SessionConfigOption, type SetConfigRequest } from "@codevisor/api"
import { Schema } from "effect"

import type { CodevisorServerServices, EventFanout } from "../server-context.js"
import { run } from "../server-context.js"
import { field } from "../unknown-values.js"
import { publishSessionConfigOptions, publishSessionSelections } from "./session-config-publish.js"
import { configRestorePriority } from "./session-config-restore.js"
import { withSessionMutation } from "./session-operations.js"
import { loadAgentSessionFor } from "./session-workspace.js"

export interface SessionConfigPickResult {
  readonly configId: string
  readonly configOptions: ReadonlyArray<SessionConfigOption>
}

export const applySessionConfigPick = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  payload: SetConfigRequest
): Promise<SessionConfigPickResult> =>
  withSessionMutation(services, sessionId, () =>
    applySessionConfigPickOwned(services, fanout, serverId, sessionId, payload)
  )

const applySessionConfigPickOwned = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  payload: SetConfigRequest
): Promise<SessionConfigPickResult> => {
  const { agentSessionId, harnessId } = await run(services.db.getSessionSummary(sessionId))
  const isRuntimeLoaded =
    agentSessionId !== undefined &&
    agentSessionId !== "" &&
    services.agents.loadedAgentSessionIds().includes(agentSessionId)
  if (!isRuntimeLoaded) {
    const runtime = await run(services.db.getSessionRuntimeState(sessionId))
    const known = persistedConfigOptions(runtime)
    const option = known.find((candidate) => candidate.id === payload.configId)
    const value =
      (option === undefined
        ? undefined
        : placeConfigValue(option, payload.value, (candidate, requested) =>
            services.agents.reconcileConfigValue(harnessId, candidate, requested)
          )) ?? payload.value
    await persistPick(services, fanout, sessionId, { [payload.configId]: value }, [
      payload.configId
    ])
    const configOptions = known.map((candidate) =>
      candidate.id === payload.configId ? { ...candidate, currentValue: value } : candidate
    )
    await publishSessionConfigOptions(services, fanout, serverId, sessionId, configOptions)
    return { configId: payload.configId, configOptions }
  }
  const agentSession = await loadAgentSessionFor(services, fanout, serverId, sessionId)
  const configOptions = await run(
    services.agents.setConfigOption(agentSession.sessionId, payload.configId, payload.value)
  )
  const picked = configOptions.find((option) => option.id === payload.configId)
  const isModelPick = picked?.category === "model" || payload.configId === "model"
  const written: Record<string, string> = { [payload.configId]: payload.value }
  for (const option of configOptions) {
    if (option.id === payload.configId || (isModelPick && isModelDependent(option))) {
      written[option.id] = option.currentValue
    }
  }
  const cleared = [
    payload.configId,
    ...(isModelPick ? agentSession.configOptions.filter(isModelDependent) : []).map(
      (option) => option.id
    )
  ]
  await persistPick(services, fanout, sessionId, written, cleared)
  return { configId: payload.configId, configOptions }
}

const isModelDependent = (option: SessionConfigOption): boolean =>
  option.category === "model_config" ||
  configRestorePriority(option) === 1 ||
  configRestorePriority(option) === 2

const persistPick = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  sessionId: string,
  written: Readonly<Record<string, string>>,
  replaced: ReadonlyArray<string>
): Promise<void> => {
  const summary = await run(services.db.getSessionSummary(sessionId))
  const without = (record: Readonly<Record<string, string>>): Record<string, string> =>
    Object.fromEntries(Object.entries(record).filter(([id]) => !replaced.includes(id)))
  await run(
    services.db.replaceSessionConfigSelections(
      sessionId,
      { ...without(summary.configSelections ?? {}), ...written },
      without(summary.unavailableConfigSelections ?? {})
    )
  )
  await publishSessionSelections(services, fanout, sessionId)
}

const persistedConfigOptions = (runtime: unknown): ReadonlyArray<SessionConfigOption> =>
  decode(Schema.Array(SessionConfigOption))(field(runtime, "configOptions"))
