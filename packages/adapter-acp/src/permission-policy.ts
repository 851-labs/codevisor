import type { SessionModeState } from "@codevisor/api"

import type { AcpPermissionOutcome } from "./questions.js"

const record = (value: unknown): Record<string, unknown> | undefined =>
  typeof value === "object" && value !== null ? (value as Record<string, unknown>) : undefined

export interface AcpPermissionPolicy {
  readonly sessionModes: (sessionId: string, modes: SessionModeState | undefined) => void
  readonly modeChanged: (sessionId: string, modeId: string) => void
  readonly automaticOutcome: (params: unknown) => AcpPermissionOutcome | undefined
}

export const makeAcpPermissionPolicy = (): AcpPermissionPolicy => {
  const modes = new Map<string, SessionModeState>()

  const gated = (sessionId: string): boolean => {
    const state = modes.get(sessionId)
    const current = state?.availableModes.find((mode) => mode.id === state.currentModeId)
    return current?.canonicalId === "plan" || current?.canonicalId === "readOnly"
  }

  return {
    sessionModes: (sessionId, state) => {
      if (state === undefined) modes.delete(sessionId)
      else modes.set(sessionId, state)
    },
    modeChanged: (sessionId, modeId) => {
      const state = modes.get(sessionId)
      if (state !== undefined) modes.set(sessionId, { ...state, currentModeId: modeId })
    },
    automaticOutcome: (params) => {
      const request = record(params)
      if (typeof request?.sessionId !== "string" || gated(request.sessionId)) return undefined
      if (record(request.toolCall)?.kind === "switch_mode") return undefined
      const options = Array.isArray(request.options) ? request.options.map(record) : []
      const allow = (kind: string) =>
        options.find((option) => option?.kind === kind && typeof option.optionId === "string")
      const option = allow("allow_once") ?? allow("allow_always")
      return option === undefined
        ? undefined
        : { outcome: { optionId: String(option.optionId), outcome: "selected" } }
    }
  }
}
