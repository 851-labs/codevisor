import { isRecord } from "@codevisor/api"
import type { SessionModeState } from "@codevisor/api"

import type { AcpPermissionOutcome } from "./questions.js"

const record = (value: unknown): Record<string, unknown> | undefined =>
  isRecord(value) ? value : undefined

export interface AcpPermissionPolicy {
  readonly sessionModes: (sessionId: string, modes: SessionModeState | undefined) => void
  readonly modeChanged: (sessionId: string, modeId: string) => void
  readonly automaticOutcome: (params: unknown) => AcpPermissionOutcome | undefined
}

const titledToolName = (toolCall: Record<string, unknown> | undefined): string => {
  if (typeof toolCall?.title !== "string") return ""
  return toolCall.title.split(":", 1)[0]?.trim() ?? ""
}

const spawnsNativeSubagent = (toolCall: Record<string, unknown> | undefined): boolean => {
  const tool = titledToolName(toolCall)
  return tool === "spawn_agent" || tool.startsWith("subagent_")
}

const switchesMode = (toolCall: Record<string, unknown> | undefined): boolean =>
  toolCall?.kind === "switch_mode"

const choose = (
  request: Record<string, unknown>,
  kinds: ReadonlyArray<string>
): AcpPermissionOutcome | undefined => {
  const options = Array.isArray(request.options) ? request.options.map(record) : []
  const matching = (kind: string) =>
    options.find((option) => option?.kind === kind && typeof option.optionId === "string")
  const option = kinds.map(matching).find((candidate) => candidate !== undefined)
  if (option === undefined) return undefined
  return { outcome: { optionId: String(option.optionId), outcome: "selected" } }
}

export interface AcpPermissionPolicyOptions {
  readonly refusesModeSwitches?: boolean
}

export const makeAcpPermissionPolicy = (
  options: AcpPermissionPolicyOptions = {}
): AcpPermissionPolicy => {
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
      if (typeof request?.sessionId !== "string") return undefined

      const toolCall = record(request.toolCall)
      if (spawnsNativeSubagent(toolCall)) return choose(request, ["reject_once", "reject_always"])
      if (switchesMode(toolCall) && options.refusesModeSwitches === true) {
        return choose(request, ["reject_once", "reject_always"])
      }
      if (gated(request.sessionId) || switchesMode(toolCall)) return undefined

      return choose(request, ["allow_once", "allow_always"])
    }
  }
}
