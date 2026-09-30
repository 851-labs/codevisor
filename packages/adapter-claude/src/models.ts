import type { Options as ClaudeOptions, Settings } from "@anthropic-ai/claude-agent-sdk"
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
  // A model the picker cannot name stays as reported, and an unset model
  // stays unset (reported as "", meaning unknown): until the CLI's init
  // names its model, presenting some row of the list would be a guess, and
  // a guess read back as the chat's selection is how picks got replaced.
  return undefined
}

/// Effort levels the CLI's flag settings accept. `max` is valid (verified
/// against a live CLI) even though the SDK's `Settings` type lags its own
/// `EffortLevel` union.
export const SETTABLE_EFFORT_LEVELS: ReadonlySet<string> = new Set([
  "low",
  "medium",
  "high",
  "xhigh",
  "max"
])

export interface ClaudeStartSelections {
  readonly model?: string | undefined
  readonly effort?: string | undefined
  readonly speed?: string | undefined
}

/// Query options that start a CLI process on the chat's selections instead
/// of the CLI's defaults. Effort and fast mode go through the flag-settings
/// layer — the same layer live changes use (`applyFlagSettings`) — so a
/// later live change replaces them rather than competing with a CLI flag.
export const claudeStartOptions = (
  selections: ClaudeStartSelections
): Pick<ClaudeOptions, "model" | "settings"> => {
  const model = selections.model === undefined ? "" : sanitizeModelValue(selections.model)
  const settings: Record<string, unknown> = {}
  if (selections.effort !== undefined && SETTABLE_EFFORT_LEVELS.has(selections.effort)) {
    settings.effortLevel = selections.effort
  }
  if (selections.speed === "fast" || selections.speed === "standard") {
    settings.fastMode = selections.speed === "fast"
  }
  return {
    ...(model.length === 0 || model === "default" ? {} : { model }),
    ...(Object.keys(settings).length === 0 ? {} : { settings: settings as Settings })
  }
}

/// The CLI's default effort for effort-capable models is "high".
const defaultEffortFor = (levels: ReadonlyArray<string>): string =>
  levels.includes("high") ? "high" : (levels[0] ?? "high")

/// A saved model id from an older CLI release reconciles onto the current
/// row's id (Fable's id drifts between releases). The process was started
/// with the saved id, so hand it the id the picker now reports.
export const alignStartModel = async (
  session: ClaudeSession,
  startModel: string | undefined
): Promise<void> => {
  if (startModel === undefined || session.currentModel === startModel) return
  if (!session.models.some((model) => model.value === session.currentModel)) return
  await session.q.setModel(session.currentModel).catch(() => undefined)
}

/// Two separate emits, deliberately: the client's `session.updated` dispatch
/// duck-types the payload and stops at the first arm that matches, so
/// folding the notice and the option snapshot into one payload would drop
/// whichever arm loses. The snapshot refreshes the picker (and the
/// effort/speed lists, which derive from the model) to what is really
/// running; it is a runtime report, never a change to the chat's saved pick.
export const emitModelFallback = (
  session: ClaudeSession,
  originalModel: string,
  fallbackModel: string,
  category: string | null
): void => {
  void session.emit({
    kind: "session.updated",
    payload: { modelFallback: { originalModel, fallbackModel, category } },
    subjectId: session.key
  })
  void session.emit({
    kind: "session.updated",
    payload: {
      configId: "model",
      configOptions: metadataFor(session).configOptions,
      value: session.currentModel
    },
    subjectId: session.key
  })
}
