import type { SessionConfigOption, SessionModeState } from "@codevisor/api"
import { findKnownModel, highestThinkingLevel, sanitizeModelValue } from "@codevisor/agent-runtime"
import type { ClaudeModel, ClaudeSession } from "./session.js"

// "Always Ask" (not the CLI's internal "default") mirrors the naming the
// claude-agent-acp adapter ships; a bare "Default" tells the user nothing.
const PERMISSION_MODES: SessionModeState = {
  currentModeId: "bypassPermissions",
  availableModes: [
    {
      id: "default",
      name: "Always Ask",
      description: "Asks before editing files or running commands.",
      canonicalId: "ask"
    },
    {
      id: "acceptEdits",
      name: "Accept Edits",
      description: "Edits files without asking; still asks before running commands.",
      canonicalId: "autoEdit"
    },
    {
      id: "plan",
      name: "Plan",
      description: "Reads and plans only; presents a plan before making changes.",
      canonicalId: "plan"
    },
    {
      id: "bypassPermissions",
      name: "Bypass Permissions",
      description: "Edits files and runs commands without asking.",
      canonicalId: "fullAccess"
    }
  ]
}

export const metadataFor = (
  session: ClaudeSession
): {
  modes: SessionModeState
  configOptions: ReadonlyArray<SessionConfigOption>
  supportsGoals: boolean
} => {
  const options: Array<SessionConfigOption> = []
  const currentModel = currentClaudeModelFor(session)
  if (session.models.length > 0) {
    options.push({
      category: "model",
      currentValue: currentModel?.value ?? session.models[0]?.value ?? session.currentModel,
      id: "model",
      name: "Model",
      options: session.models.map((model) => ({ name: model.name, value: model.value }))
    })
  }
  const effortLevels = effortLevelsFor(session)
  if (effortLevels.length > 0) {
    options.push({
      category: "thought_level",
      // No synthetic "Default" entry: until the user picks a level the CLI
      // runs at its own default ("high" on effort-capable models), so
      // surface that as the selection.
      currentValue: effortLevels.includes(session.currentEffort)
        ? session.currentEffort
        : defaultEffortFor(effortLevels),
      id: "effort",
      name: "Effort",
      options: effortLevels.map((level) => ({
        name: level === "xhigh" ? "X-High" : (level[0]?.toUpperCase() ?? "") + level.slice(1),
        value: level
      }))
    })
  }
  if (supportsFastMode(session)) {
    options.push({
      category: "speed",
      currentValue: session.currentSpeed,
      id: "speed",
      name: "Speed",
      options: [
        { name: "Standard", value: "standard" },
        { description: "Prioritized, faster responses", name: "Fast", value: "fast" }
      ]
    })
  }
  return { configOptions: options, modes: PERMISSION_MODES, supportsGoals: true }
}

export const effortLevelsFor = (session: ClaudeSession): ReadonlyArray<string> =>
  currentClaudeModelFor(session)?.supportedEffortLevels ?? []

export const supportsFastMode = (session: ClaudeSession): boolean =>
  currentClaudeModelFor(session)?.supportsFastMode === true

const claudeModelFamily = (value: string): string | undefined => {
  const normalized = sanitizeModelValue(value).toLowerCase()
  return ["opus", "sonnet", "haiku", "fable"].find(
    (family) =>
      normalized === family ||
      normalized.startsWith(`${family}[`) ||
      normalized.includes(`-${family}-`) ||
      normalized.endsWith(`-${family}`)
  )
}

const knownClaudeModelFromProvider = (
  models: ReadonlyArray<ClaudeModel>,
  value: string
): ClaudeModel | undefined => {
  const exact = findKnownModel(models, value)
  if (exact !== undefined) return exact

  // Claude's runtime events use concrete ids (`claude-opus-4-8`) while
  // supportedModels can expose settable aliases (`opus[1m]`). Reconcile a
  // concrete id only when its family identifies exactly one picker option;
  // choosing between multiple aliases would invent information the event
  // does not carry (for example ordinary vs 1M context).
  const family = claudeModelFamily(value)
  if (family === undefined) return undefined
  const familyMatches = models.filter((model) => claudeModelFamily(model.value) === family)
  return familyMatches.length === 1 ? familyMatches[0] : undefined
}

/// Applies a provider-reported model where it maps unambiguously to the
/// picker and returns the best truthful value for notices. An unknown model
/// leaves the picker unchanged but is returned raw so callers never relabel
/// it as the previous model.
export const applyClaudeModelFromProvider = (session: ClaudeSession, value: string): string => {
  const sanitized = sanitizeModelValue(value)
  if (session.models.length === 0) {
    session.currentModel = sanitized
    return sanitized
  }
  const matched = knownClaudeModelFromProvider(session.models, sanitized)
  if (matched !== undefined) {
    session.currentModel = matched.value
    return matched.value
  }
  currentClaudeModelFor(session)
  return sanitized
}

export const currentClaudeModelFor = (session: ClaudeSession): ClaudeModel | undefined => {
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
  const hadUntrustedModel = session.currentModel.length > 0 && session.currentModel !== "default"
  session.currentModel = fallback.value
  if (hadUntrustedModel) {
    session.currentEffort = highestThinkingLevel(fallback.supportedEffortLevels) ?? "default"
  }
  return fallback
}

/// The CLI's default effort for effort-capable models is "high".
const defaultEffortFor = (levels: ReadonlyArray<string>): string =>
  levels.includes("high") ? "high" : (levels[0] ?? "high")
