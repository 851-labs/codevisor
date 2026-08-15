import type {
  SessionConfigOption as AcpSessionConfigOption,
  SessionConfigSelectGroup as AcpSessionConfigSelectGroup,
  SessionConfigSelectOption as AcpSessionConfigSelectOption,
  SessionMode as AcpSessionMode,
  SessionModeState as AcpSessionModeState
} from "@agentclientprotocol/sdk"
import type {
  CanonicalModeId,
  SessionConfigOption,
  SessionConfigSelectGroup,
  SessionConfigSelectOption,
  SessionModeState
} from "@codevisor/api"
import type { AgentSessionMetadata } from "@codevisor/agent-runtime"
import { grokModeState } from "./grok.js"
import {
  acpModelConfigOption,
  acpReasoningEffortConfigId,
  acpReasoningEffortConfigOption,
  type AcpModelState
} from "./model-selection.js"

export const acpConfigSelection = (
  harnessId: string | undefined,
  configId: string,
  value: string
): { readonly configId: string; readonly value: string } =>
  harnessId === "cursor" && configId === "speed"
    ? { configId: "fast", value: value === "fast" ? "true" : "false" }
    : { configId, value }

export interface AcpSessionMetadataResponse {
  readonly configOptions?: ReadonlyArray<AcpSessionConfigOption> | null
  readonly modes?: AcpSessionModeState | null
}

export const sessionMetadata = (
  sessionId: string,
  response: AcpSessionMetadataResponse,
  modelState: AcpModelState | undefined,
  harnessId?: string
): AgentSessionMetadata => {
  const configOptions = normalizeAcpConfigOptions(response.configOptions ?? [], harnessId)
  // Append each synthesized picker unless the adapter already reported an
  // equivalent native option — don't double up.
  const withModel = [...configOptions]
  if (modelState !== undefined) {
    if (!withModel.some((option) => option.category === "model")) {
      withModel.push(acpModelConfigOption(modelState))
    }
    const reasoning = acpReasoningEffortConfigOption(modelState)
    if (
      reasoning !== undefined &&
      !withModel.some((option) => option.id === acpReasoningEffortConfigId)
    ) {
      withModel.push(reasoning)
    }
  }
  const modes =
    response.modes === undefined || response.modes === null
      ? harnessId === "grok-build"
        ? grokModeState
        : undefined
      : normalizeModeState(response.modes)
  return {
    sessionId,
    ...(modes === undefined ? {} : { modes }),
    ...(harnessId === "grok-build" ? { supportsGoals: true } : {}),
    configOptions: withModel
  }
}

/// Best-effort mapping from agent-defined ACP mode ids/names onto Codevisor's
/// canonical vocabulary. Order matters: the first matching pattern wins.
/// Unmapped modes stay native-only and render in the picker's overflow section.
const CANONICAL_MODE_PATTERNS: ReadonlyArray<{
  readonly canonicalId: CanonicalModeId
  readonly pattern: RegExp
}> = [
  { canonicalId: "plan", pattern: /^plan/i },
  { canonicalId: "readOnly", pattern: /read[-_ ]?only/i },
  { canonicalId: "autoEdit", pattern: /accept[-_ ]?edits|auto[-_ ]?edit/i },
  { canonicalId: "fullAccess", pattern: /bypass|full[-_ ]?access|yolo/i },
  { canonicalId: "ask", pattern: /^(default|ask|normal)$/i }
]

const canonicalModeIdFor = (mode: AcpSessionMode): CanonicalModeId | undefined =>
  CANONICAL_MODE_PATTERNS.find(
    (entry) => entry.pattern.test(mode.id) || entry.pattern.test(mode.name)
  )?.canonicalId

export const normalizeModeState = (state: AcpSessionModeState): SessionModeState => ({
  currentModeId: state.currentModeId,
  availableModes: state.availableModes.map((mode) => {
    const canonicalId = canonicalModeIdFor(mode)
    return {
      id: mode.id,
      name: mode.name,
      ...(mode.description === undefined || mode.description === null
        ? {}
        : { description: mode.description }),
      ...(canonicalId === undefined ? {} : { canonicalId })
    }
  })
})

export const normalizeAcpConfigOptions = (
  options: ReadonlyArray<AcpSessionConfigOption>,
  harnessId?: string
): ReadonlyArray<SessionConfigOption> =>
  options.flatMap((option) => {
    if (option.type !== "select" || typeof option.currentValue !== "string") {
      return []
    }
    if (harnessId === "cursor" && option.id === "context") return []
    if (harnessId === "cursor" && option.id === "fast") {
      return [
        {
          id: "speed",
          name: "Speed",
          ...(option.description === undefined || option.description === null
            ? {}
            : { description: option.description }),
          category: "speed",
          currentValue: option.currentValue === "true" ? "fast" : "standard",
          options: [
            { name: "Standard", value: "standard" },
            { name: "Fast", value: "fast" }
          ]
        }
      ]
    }
    return [
      {
        id: option.id,
        name: option.name,
        ...(option.description === undefined || option.description === null
          ? {}
          : { description: option.description }),
        ...(option.category === undefined || option.category === null
          ? {}
          : { category: option.category }),
        currentValue: option.currentValue,
        options: normalizeSelectOptions(option.options, option.category)
      }
    ]
  })

const normalizeSelectOptions = (
  options: ReadonlyArray<AcpSessionConfigSelectOption> | ReadonlyArray<AcpSessionConfigSelectGroup>,
  category: string | null | undefined
): ReadonlyArray<SessionConfigSelectOption> | ReadonlyArray<SessionConfigSelectGroup> => {
  const first = options[0]
  if (first !== undefined && "group" in first) {
    return (options as ReadonlyArray<AcpSessionConfigSelectGroup>).map((group) => ({
      group: group.group,
      name: group.name,
      options: group.options.map((option) => normalizeSelectOption(option, category))
    }))
  }
  return (options as ReadonlyArray<AcpSessionConfigSelectOption>).map((option) =>
    normalizeSelectOption(option, category)
  )
}

const normalizeSelectOption = (
  option: AcpSessionConfigSelectOption,
  category: string | null | undefined
): SessionConfigSelectOption => ({
  value: option.value,
  name:
    category === "thought_level"
      ? option.name.replace(/^(?:Thinking|Reasoning):\s*/i, "")
      : option.name,
  ...(option.description === undefined || option.description === null
    ? {}
    : { description: option.description })
})
