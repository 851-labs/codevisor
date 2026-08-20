import type * as acp from "@agentclientprotocol/sdk"
import type { CanonicalModeId, SessionConfigOption } from "@codevisor/api"
import type { AgentSessionMetadata } from "@codevisor/agent-runtime"

export const cursorClientCapabilities = (
  capabilities: acp.ClientCapabilities
): acp.ClientCapabilities => ({
  ...capabilities,
  _meta: { ...capabilities._meta, parameterizedModelPicker: true }
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
    return [
      {
        id: "speed",
        name: "Speed",
        ...(option.description === undefined ? {} : { description: option.description }),
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

export const cursorSessionMetadata = (metadata: AgentSessionMetadata): AgentSessionMetadata => ({
  ...metadata,
  configOptions: normalizeCursorConfigOptions(metadata.configOptions),
  ...(metadata.modes === undefined
    ? {}
    : {
        modes: {
          ...metadata.modes,
          availableModes: metadata.modes.availableModes.map((mode) => {
            const canonicalId = cursorCanonicalMode(mode.id)
            return canonicalId === undefined ? mode : { ...mode, canonicalId }
          })
        }
      })
})
