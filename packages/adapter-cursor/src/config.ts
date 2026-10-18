import type * as acp from "@agentclientprotocol/sdk"
import type { AgentSessionMetadata } from "@codevisor/agent-runtime"
import type { CanonicalModeId, SessionConfigOption } from "@codevisor/api"

import { CURSOR_SUBAGENTS_CAPABILITY } from "./subagents.js"

export const cursorClientCapabilities = (
  capabilities: acp.ClientCapabilities
): acp.ClientCapabilities => ({
  ...capabilities,
  _meta: {
    ...capabilities._meta,
    parameterizedModelPicker: true,
    [CURSOR_SUBAGENTS_CAPABILITY]: true
  }
})

export const cursorConfigSelection = (
  configId: string,
  value: string
): { readonly configId: string; readonly value: string } =>
  configId === "speed"
    ? { configId: "fast", value: value === "fast" ? "true" : "false" }
    : { configId, value }

export const normalizeCursorConfigOptions = (
  options: ReadonlyArray<SessionConfigOption>
): ReadonlyArray<SessionConfigOption> =>
  options.flatMap((option) => {
    if (option.id === "context") return []
    if (option.id !== "fast") return [option]
    const speed: { id: string; name: string; description?: string } = {
      id: "speed",
      name: "Speed"
    }
    if (option.description !== undefined) speed.description = option.description
    return [
      {
        ...speed,
        category: "speed",
        currentValue: option.currentValue === "true" ? "fast" : "standard",
        options: [
          { name: "Standard", value: "standard" },
          { name: "Fast", value: "fast" }
        ]
      }
    ]
  })

const cursorCanonicalMode = (id: string): CanonicalModeId | undefined => {
  switch (id) {
    case "agent":
    case "code":
      return "fullAccess"
    case "plan":
    case "architect":
      return "plan"
    case "ask":
    case "chat":
      return "ask"
    default:
      return undefined
  }
}

const cursorSessionModes = (metadata: AgentSessionMetadata): AgentSessionMetadata["modes"] => {
  if (metadata.modes === undefined) return undefined
  return {
    ...metadata.modes,
    availableModes: metadata.modes.availableModes.map((mode) => {
      const canonicalId = cursorCanonicalMode(mode.id)
      return canonicalId === undefined ? mode : { ...mode, canonicalId }
    })
  }
}

export const cursorSessionMetadata = (metadata: AgentSessionMetadata): AgentSessionMetadata => {
  const normalized = {
    ...metadata,
    configOptions: normalizeCursorConfigOptions(metadata.configOptions)
  }
  const modes = cursorSessionModes(metadata)
  if (modes !== undefined) normalized.modes = modes
  return normalized
}
