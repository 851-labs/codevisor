import type { CodevisorServerServices } from "../server-context.js"

export const isRuntimeLoaded = (
  services: CodevisorServerServices,
  agentSessionId: string | undefined
): agentSessionId is string =>
  agentSessionId !== undefined && services.agents.loadedAgentSessionIds().includes(agentSessionId)
