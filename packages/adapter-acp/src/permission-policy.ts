import type { SessionModeState } from "@codevisor/api"

import type { AcpPermissionOutcome } from "./questions.js"

/// Codevisor runs every harness with full access: Claude in
/// bypassPermissions, Codex never asking for approval, Cursor with --force.
/// ACP agents ask through `session/request_permission` instead, so their
/// requests are answered here with the agent's own "allow" option rather
/// than shown to the user.
///
/// Plan and read-only modes still ask: their permission requests are what
/// keep the agent from editing. Leaving plan mode always asks too, since
/// that request is the user's approval of the plan.

const record = (value: unknown): Record<string, unknown> | undefined =>
  typeof value === "object" && value !== null ? (value as Record<string, unknown>) : undefined

export interface AcpPermissionPolicy {
  /// A session's modes as `session/new` or `session/load` reported them.
  readonly sessionModes: (sessionId: string, modes: SessionModeState | undefined) => void
  /// The session switched mode, by request or as the agent reported.
  readonly modeChanged: (sessionId: string, modeId: string) => void
  /// The answer to give without asking, or undefined to ask the user.
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
      // Once, so the agent doesn't save a rule of its own that outlives Codevisor's policy.
      const option = allow("allow_once") ?? allow("allow_always")
      return option === undefined
        ? undefined
        : { outcome: { optionId: String(option.optionId), outcome: "selected" } }
    }
  }
}
