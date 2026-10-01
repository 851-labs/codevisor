import { placeConfigValue } from "@codevisor/agent-runtime"
import type { SessionConfigOption, SetConfigRequest } from "@codevisor/api"

import type { CodevisorServerServices, EventFanout } from "../server-context.js"
import { run } from "../server-context.js"
import { withSessionMutation } from "./session-operations.js"
import { configRestorePriority, loadAgentSessionFor } from "./session-workspace.js"

export interface SessionConfigPickResult {
  readonly configId: string
  readonly configOptions: ReadonlyArray<SessionConfigOption>
}

/// Applies one picker change. An explicit pick is the only thing that writes
/// a chat's saved selections, and it writes only what was picked: the
/// option itself and, for a model pick, the options that depend on the model
/// (reasoning, speed, model config) as the runtime resolved them for the new
/// model. Nothing else the runtime reports is persisted, so a drifted value
/// elsewhere in the snapshot can never overwrite an earlier pick.
///
/// With a live runtime the harness answers with the resulting option list,
/// and a value it cannot apply fails the pick. Without one, the choice is
/// only recorded: launching a harness process just to tell it a preference
/// is what made the composer pickers hang, and the next connect or prompt
/// restores saved selections against the live list anyway — which is also
/// where an unavailable value gets reported.
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
    // Land a drifted id on the entry the last known list offers; a value
    // that list does not know is recorded as picked — the list may be stale,
    // and the next restore reports it if the runtime really lacks it.
    const option = known.find((candidate) => candidate.id === payload.configId)
    const value =
      (option === undefined
        ? undefined
        : placeConfigValue(option, payload.value, (candidate, requested) =>
            services.agents.reconcileConfigValue(harnessId, candidate, requested)
          )) ?? payload.value
    await persistPick(services, sessionId, { [payload.configId]: value }, [payload.configId])
    const configOptions = known.map((candidate) =>
      candidate.id === payload.configId ? { ...candidate, currentValue: value } : candidate
    )
    return { configId: payload.configId, configOptions }
  }
  const agentSession = await loadAgentSessionFor(services, fanout, serverId, sessionId)
  const configOptions = await run(
    services.agents.setConfigOption(agentSession.sessionId, payload.configId, payload.value)
  )
  const picked = configOptions.find((option) => option.id === payload.configId)
  const isModelPick = picked?.category === "model" || payload.configId === "model"
  // The runtime's value for the pick (a drifted id lands on its current
  // entry). For a model pick, also the options the model decides — the
  // runtime's resolution of reasoning and speed for the new model (its
  // default when the earlier level is not offered) — and dependents the new
  // model no longer has are dropped.
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
  await persistPick(services, sessionId, written, cleared)
  return { configId: payload.configId, configOptions }
}

const isModelDependent = (option: SessionConfigOption): boolean =>
  option.category === "model_config" ||
  configRestorePriority(option) === 1 ||
  configRestorePriority(option) === 2

/// Merges `written` into the saved selections; every id in `replaced` is
/// dropped first (so a dependent the new model lacks goes away) and loses
/// its unavailable mark — an explicit pick answers it.
const persistPick = async (
  services: CodevisorServerServices,
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
}

/// The last option snapshot a runtime published for this chat. A pick
/// recorded while no runtime is up is reflected onto it so the client gets
/// an answer shaped like a live one. The store always answers with an
/// object whose `configOptions` is an array (empty when nothing was
/// published), so the untyped value is read as that shape.
const persistedConfigOptions = (runtime: unknown): ReadonlyArray<SessionConfigOption> =>
  (runtime as { readonly configOptions: ReadonlyArray<SessionConfigOption> }).configOptions
