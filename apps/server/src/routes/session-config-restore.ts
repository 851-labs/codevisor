import { placeConfigValue, type AgentSessionMetadata } from "@codevisor/agent-runtime"
import type { SessionConfigOption } from "@codevisor/api"

import { run, type CodevisorServerServices, type EventFanout } from "../server-context.js"
import { publishSessionConfigOptions, publishSessionSelections } from "./session-config-publish.js"

export const configRestorePriority = (option: SessionConfigOption | undefined): number => {
  if (option?.category === "model" || option?.id === "model") return 0
  if (option?.category === "thought_level") return 1
  if (option?.category === "speed" || option?.id === "speed") return 2
  return 3
}

export const restoreSessionConfigSelections = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  metadata: AgentSessionMetadata
): Promise<AgentSessionMetadata> => {
  if (metadata.configOptions.length === 0) {
    await run(services.db.saveSessionRuntimeState(sessionId, metadata))
    return metadata
  }
  const summary = await run(services.db.getSessionSummary(sessionId))
  const saved = summary.configSelections ?? {}
  const previouslyUnavailable = summary.unavailableConfigSelections ?? {}
  const reconcile = (option: SessionConfigOption, value: string): string | undefined =>
    services.agents.reconcileConfigValue(summary.harnessId, option, value)
  let configOptions = metadata.configOptions
  const migrated: Record<string, string> = {}
  const unavailable: Record<string, string> = Object.fromEntries(
    Object.entries(previouslyUnavailable).filter(([configId, value]) => saved[configId] === value)
  )
  const ordered = Object.entries(saved).toSorted(([leftId], [rightId]) => {
    const left = configOptions.find((option) => option.id === leftId)
    const right = configOptions.find((option) => option.id === rightId)
    const difference = configRestorePriority(left) - configRestorePriority(right)
    return difference === 0 ? leftId.localeCompare(rightId) : difference
  })
  for (const [configId, value] of ordered) {
    const option = configOptions.find((candidate) => candidate.id === configId)
    if (option === undefined) continue
    const restored = placeConfigValue(option, value, reconcile)
    if (restored === undefined) {
      console.error(
        `[session-config] ${sessionId}: saved ${configId}=${value} is no longer offered; keeping it as unavailable`
      )
      unavailable[configId] = value
      continue
    }
    delete unavailable[configId]
    if (restored !== value) migrated[configId] = restored
    if (option.currentValue === restored) continue
    try {
      configOptions = await run(
        services.agents.setConfigOption(metadata.sessionId, configId, restored)
      )
    } catch (error) {
      console.error(
        `[session-config] ${sessionId}: could not restore ${configId}=${restored}: ${String(error)}`
      )
    }
  }
  const selections = { ...saved, ...migrated }
  if (!sameSelections(selections, saved) || !sameSelections(unavailable, previouslyUnavailable)) {
    await run(services.db.replaceSessionConfigSelections(sessionId, selections, unavailable))
    await publishSessionSelections(services, fanout, sessionId)
  }
  await publishSessionConfigOptions(services, fanout, serverId, sessionId, configOptions)
  const current = { ...metadata, configOptions }
  await run(services.db.saveSessionRuntimeState(sessionId, current))
  return current
}

const sameSelections = (
  left: Readonly<Record<string, string>>,
  right: Readonly<Record<string, string>>
): boolean =>
  Object.keys(left).length === Object.keys(right).length &&
  Object.entries(left).every(([key, value]) => right[key] === value)
