import type {
  SessionConfigOption as AcpSessionConfigOption,
  SessionMode as AcpSessionMode,
  SessionModeState as AcpSessionModeState
} from "@agentclientprotocol/sdk"
import type { AgentSessionMetadata } from "@codevisor/agent-runtime"
import {
  isPlainRecord,
  type CanonicalModeId,
  type SessionConfigOption,
  type SessionConfigSelectGroup,
  type SessionConfigSelectOption,
  type SessionModeState
} from "@codevisor/api"

export interface AcpSessionMetadataResponse {
  readonly configOptions?: ReadonlyArray<AcpSessionConfigOption> | null
  readonly modes?: AcpSessionModeState | null
}

export const sessionMetadata = (
  sessionId: string,
  response: AcpSessionMetadataResponse
): AgentSessionMetadata => {
  const configOptions = normalizeAcpConfigOptions(response.configOptions ?? [])
  const modes =
    response.modes === undefined || response.modes === null
      ? undefined
      : normalizeModeState(response.modes)
  return {
    sessionId,
    ...(modes === undefined ? {} : { modes }),
    configOptions
  }
}

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

const conciseThoughtLevelName = (name: string, category: string | undefined): string => {
  if (category !== "thought_level") return name
  const withoutPrefix = name.replace(/^(?:Thinking|Reasoning):\s*/i, "").trim()
  const withoutEffort = withoutPrefix.replace(/\s+effort$/i, "").trim()
  return withoutEffort === "" ? name : withoutEffort
}

const optionalText = (value: unknown): string | undefined =>
  typeof value === "string" ? value : undefined

const list = (value: unknown): ReadonlyArray<unknown> => (Array.isArray(value) ? value : [])

export const normalizeAcpConfigOptions = (
  options: ReadonlyArray<unknown>
): ReadonlyArray<SessionConfigOption> =>
  options.flatMap((option) => {
    if (
      !isPlainRecord(option) ||
      option.type !== "select" ||
      typeof option.id !== "string" ||
      typeof option.name !== "string" ||
      typeof option.currentValue !== "string"
    ) {
      return []
    }
    const category = optionalText(option.category)
    const description = optionalText(option.description)
    return [
      {
        id: option.id,
        name: conciseThoughtLevelName(option.name, category),
        ...(description === undefined ? {} : { description }),
        ...(category === undefined ? {} : { category }),
        currentValue: option.currentValue,
        options: normalizeSelectOptions(list(option.options), category)
      }
    ]
  })

const normalizeSelectOptions = (
  options: ReadonlyArray<unknown>,
  category: string | undefined
): ReadonlyArray<SessionConfigSelectOption> | ReadonlyArray<SessionConfigSelectGroup> => {
  const first = options[0]
  if (isPlainRecord(first) && "group" in first) {
    return options.flatMap((group) =>
      isPlainRecord(group) && typeof group.group === "string" && typeof group.name === "string"
        ? [
            {
              group: group.group,
              name: group.name,
              options: normalizeSelectOptionList(list(group.options), category)
            }
          ]
        : []
    )
  }
  return normalizeSelectOptionList(options, category)
}

const normalizeSelectOptionList = (
  options: ReadonlyArray<unknown>,
  category: string | undefined
): ReadonlyArray<SessionConfigSelectOption> =>
  options.flatMap((option) => {
    if (!isPlainRecord(option) || typeof option.value !== "string") return []
    if (typeof option.name !== "string") return []
    const description = optionalText(option.description)
    return [
      {
        value: option.value,
        name: conciseThoughtLevelName(option.name, category),
        ...(description === undefined ? {} : { description })
      }
    ]
  })
