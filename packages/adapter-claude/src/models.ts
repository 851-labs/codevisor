import { findKnownModel, sanitizeModelValue } from "@codevisor/agent-runtime"
import type { SessionConfigOption, SessionModeState } from "@codevisor/api"

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
      currentValue: currentModel?.value ?? session.currentModel,
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
  return {
    configOptions: options,
    modes: { ...PERMISSION_MODES, currentModeId: session.currentModeId },
    supportsGoals: true
  }
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

const knownClaudeModelFromProvider = <Model extends { readonly value: string }>(
  models: ReadonlyArray<Model>,
  value: string
): Model | undefined => {
  const exact = findKnownModel(models, value)
  if (exact !== undefined) return exact

  // Claude's runtime events use concrete ids (`claude-opus-4-8`) while
  // supportedModels can expose settable aliases (`opus[1m]`). Reconcile a
  // concrete id by family; when the family offers several aliases they
  // differ by context window, and the id's own `[1m]` suffix says which
  // one applies. Anything still ambiguous stays unresolved rather than
  // inventing information the value does not carry.
  const family = claudeModelFamily(value)
  if (family === undefined) return undefined
  const familyMatches = models.filter((model) => claudeModelFamily(model.value) === family)
  if (familyMatches.length <= 1) return familyMatches[0]
  const wantsLongContext = hasLongContextSuffix(value)
  const sameWindow = familyMatches.filter(
    (model) => hasLongContextSuffix(model.value) === wantsLongContext
  )
  return sameWindow.length === 1 ? sameWindow[0] : undefined
}

const hasLongContextSuffix = (value: string): boolean => /\[1m\]$/i.test(sanitizeModelValue(value))

/// The picker row a requested model maps to. Fable's concrete id changes
/// between CLI releases (`claude-fable-5` → `claude-fable-5[1m]` →
/// `claude-fable-5-1[1m]`), so a value remembered by an older release or a
/// stale catalog still needs to land on the current row rather than being
/// treated as some other model.
export const resolveClaudeModel = <Model extends { readonly value: string }>(
  models: ReadonlyArray<Model>,
  value: string
): Model | undefined => knownClaudeModelFromProvider(models, sanitizeModelValue(value))

/// The id to hand the CLI for a picker request. Unknown values are refused
/// instead of being sent through and then reported back as another row.
export const resolveRequestedClaudeModel = (session: ClaudeSession, value: string): string => {
  const sanitized = sanitizeModelValue(value)
  if (session.models.length === 0) return sanitized
  const matched = resolveClaudeModel(session.models, sanitized)
  if (matched === undefined) {
    throw new Error(`Model "${sanitized}" is not available in this Claude session`)
  }
  return matched.value
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
  const matched = knownClaudeModelFromProvider(session.models, session.currentModel)
  if (matched !== undefined) {
    session.currentModel = matched.value
    return matched
  }
  // A model the session was told about but the picker cannot name stays
  // as reported: presenting it as the list's first row would misreport
  // what the CLI is actually running. Only an unset model takes the
  // first entry, which is the CLI's own default.
  if (session.currentModel.length > 0 && session.currentModel !== "default") return undefined
  const fallback = session.models[0]
  if (fallback === undefined) return undefined
  session.currentModel = fallback.value
  return fallback
}

/// The CLI's default effort for effort-capable models is "high".
const defaultEffortFor = (levels: ReadonlyArray<string>): string =>
  levels.includes("high") ? "high" : (levels[0] ?? "high")
