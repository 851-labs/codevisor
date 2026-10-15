import type {
  Options as ClaudeOptions,
  PermissionMode,
  Settings
} from "@anthropic-ai/claude-agent-sdk"
import { findKnownModel, sanitizeModelValue } from "@codevisor/agent-runtime"
import type { SessionConfigOption, SessionModeState } from "@codevisor/api"

import type { ClaudeModel, ClaudeSession } from "./session.js"

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

const PERMISSION_MODE_IDS: ReadonlyArray<string> = [
  "default",
  "acceptEdits",
  "bypassPermissions",
  "plan",
  "dontAsk",
  "auto"
] satisfies ReadonlyArray<PermissionMode>

export const isPermissionMode = (modeId: string): modeId is PermissionMode =>
  PERMISSION_MODE_IDS.includes(modeId)

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

export const resolveClaudeModel = <Model extends { readonly value: string }>(
  models: ReadonlyArray<Model>,
  value: string
): Model | undefined => knownClaudeModelFromProvider(models, sanitizeModelValue(value))

export const resolveRequestedClaudeModel = (session: ClaudeSession, value: string): string => {
  const sanitized = sanitizeModelValue(value)
  if (session.models.length === 0) return sanitized
  const matched = resolveClaudeModel(session.models, sanitized)
  if (matched === undefined) {
    throw new Error(`Model "${sanitized}" is not available in this Claude session`)
  }
  return matched.value
}

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
  return undefined
}

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
  readonly skillOverrides?: Settings["skillOverrides"]
}

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
  if (selections.skillOverrides !== undefined) settings.skillOverrides = selections.skillOverrides
  return {
    ...(model.length === 0 || model === "default" ? {} : { model }),
    ...(Object.keys(settings).length === 0 ? {} : { settings })
  }
}

const defaultEffortFor = (levels: ReadonlyArray<string>): string =>
  levels.includes("high") ? "high" : (levels[0] ?? "high")

export const alignStartModel = async (
  session: ClaudeSession,
  startModel: string | undefined
): Promise<void> => {
  if (startModel === undefined || session.currentModel === startModel) return
  if (!session.models.some((model) => model.value === session.currentModel)) return
  await session.q.setModel(session.currentModel).catch(() => undefined)
}

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

type SupportedModel = Awaited<ReturnType<ClaudeSession["q"]["supportedModels"]>>[number]

const versionedDisplayName = (model: SupportedModel): string => {
  const [, family = "", suffix = ""] = /^(\S+)(\s+\(.*\))?$/.exec(model.displayName) ?? []
  const lead = model.description.split(" · ")[0]?.trim() ?? ""
  if (family === "" || !lead.startsWith(`${family} `)) return model.displayName
  const version = lead.slice(family.length + 1)
  return /^\d+(\.\d+)*$/.test(version) ? `${lead}${suffix}` : model.displayName
}

export const adoptModelList = (
  session: ClaudeSession,
  models: ReadonlyArray<SupportedModel>
): void => {
  session.models = models
    .filter((model) => model.value !== "default")
    .map((model) => ({
      name: versionedDisplayName(model),
      supportedEffortLevels: (model.supportsEffort === true
        ? (model.supportedEffortLevels ?? [])
        : []
      ).filter((level) => SETTABLE_EFFORT_LEVELS.has(level)),
      supportsFastMode: model.supportsFastMode === true,
      value: model.value
    }))
}
