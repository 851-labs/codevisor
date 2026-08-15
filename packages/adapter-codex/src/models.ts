import type { CanonicalModeId, SessionConfigOption, SessionModeState } from "@codevisor/api"
import { findKnownModel, highestThinkingLevel, sanitizeModelValue } from "@codevisor/agent-runtime"
import type { CodexModel, CodexSession } from "./session.js"

/// The wire value Codex uses for its fast service tier (the UI calls it
/// "priority"); "default" is the explicit standard-routing sentinel.
export const CODEX_FAST_TIER = "priority"
export const CODEX_STANDARD_TIER = "default"

/// Approval/sandbox presets, mirroring the modes the codex-acp adapter (and
/// the Codex IDE extensions) expose. Applied as sticky turn/start overrides.
export interface CodexMode {
  readonly id: string
  readonly name: string
  readonly description: string
  readonly canonicalId: CanonicalModeId
  readonly approvalPolicy: string
  readonly sandboxPolicy: Record<string, unknown>
  /// When set, turn/start also sends the EXPERIMENTAL collaborationMode
  /// preset (unlocked by `capabilities.experimentalApi` at initialize).
  readonly collaboration?: "plan"
}

export const CODEX_MODES: ReadonlyArray<CodexMode> = [
  {
    approvalPolicy: "never",
    canonicalId: "plan",
    collaboration: "plan",
    description: "Plans first with full system access and no command approvals.",
    id: "plan",
    name: "Plan",
    sandboxPolicy: { type: "dangerFullAccess" }
  },
  {
    approvalPolicy: "on-request",
    canonicalId: "readOnly",
    description: "Requires approval to edit files and run commands.",
    id: "read-only",
    name: "Read-only",
    sandboxPolicy: { networkAccess: false, type: "readOnly" }
  },
  {
    approvalPolicy: "on-request",
    canonicalId: "ask",
    description: "Read and edit files, and run commands.",
    id: "agent",
    name: "Agent",
    sandboxPolicy: {
      excludeSlashTmp: false,
      excludeTmpdirEnvVar: false,
      networkAccess: false,
      type: "workspaceWrite",
      writableRoots: []
    }
  },
  {
    approvalPolicy: "never",
    canonicalId: "fullAccess",
    description:
      "Codex can edit files outside this workspace and run commands with network access.",
    id: "agent-full-access",
    name: "Agent (full access)",
    sandboxPolicy: { type: "dangerFullAccess" }
  }
]

export const DEFAULT_CODEX_MODE = "agent-full-access"

export const configOptionsFor = (session: CodexSession): ReadonlyArray<SessionConfigOption> => {
  const options: Array<SessionConfigOption> = []
  const current = currentCodexModelFor(session)
  if (current !== undefined) {
    options.push({
      category: "model",
      currentValue: current.value,
      id: "model",
      name: "Model",
      options: session.models.map((model) => ({ name: model.name, value: model.value }))
    })
  }
  const efforts = current?.efforts ?? []
  if (efforts.length > 0) {
    options.push({
      category: "thought_level",
      currentValue:
        session.currentEffort !== undefined && efforts.includes(session.currentEffort)
          ? session.currentEffort
          : (current?.defaultEffort ?? efforts[0] ?? "medium"),
      id: "effort",
      name: "Reasoning",
      options: efforts.map((effort) => ({
        name: effort === "xhigh" ? "X-High" : effort[0]?.toUpperCase() + effort.slice(1),
        value: effort
      }))
    })
  }
  if (current?.supportsFast === true) {
    options.push({
      category: "speed",
      currentValue: effectiveSpeed(session) ?? "standard",
      id: "speed",
      name: "Speed",
      options: [
        { name: "Standard", value: "standard" },
        { description: "Prioritized, faster responses", name: "Fast", value: "fast" }
      ]
    })
  }
  return options
}

/// The speed the next turn runs at: the user's pick, else the current
/// model's catalog default. Undefined when the model has no fast tier.
export const effectiveSpeed = (session: CodexSession): "standard" | "fast" | undefined => {
  const current = currentCodexModelFor(session)
  if (current?.supportsFast !== true) return undefined
  return session.currentSpeed ?? (current.defaultsToFast ? "fast" : "standard")
}

export const currentCodexModelFor = (session: CodexSession): CodexModel | undefined => {
  if (session.models.length === 0) {
    session.currentModel = sanitizeModelValue(session.currentModel)
    return undefined
  }
  const matched = findKnownModel(session.models, session.currentModel)
  if (matched !== undefined) {
    session.currentModel = matched.value
    return matched
  }
  const fallback = session.models[0]
  if (fallback === undefined) return undefined
  session.currentModel = fallback.value
  session.currentEffort = highestThinkingLevel(fallback.efforts) ?? fallback.defaultEffort
  session.currentSpeed = undefined
  return fallback
}

export const modesFor = (session: CodexSession): SessionModeState => ({
  availableModes: CODEX_MODES.map((mode) => ({
    canonicalId: mode.canonicalId,
    description: mode.description,
    id: mode.id,
    name: mode.name
  })),
  currentModeId: session.currentModeId
})
