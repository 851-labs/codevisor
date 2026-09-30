import type { SessionConfigOption } from "@codevisor/api"

const ansiEscapePattern =
  // oxlint-disable-next-line no-control-regex -- matches ESC/CSI/BEL deliberately to strip ANSI escape sequences
  /[\u001B\u009B][[\]()#;?]*(?:(?:(?:[a-zA-Z\d]*(?:;[a-zA-Z\d]*)*)?\u0007)|(?:(?:\d{1,4}(?:;\d{0,4})*)?[\dA-PR-TZcf-nq-uy=><~]))/g
// oxlint-disable-next-line no-control-regex -- matches C0 control characters and DEL deliberately to strip them
const controlCharacterPattern = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g
const trailingSgrFragmentPattern = /(?:\[\d+(?:;\d+)*m)+$/g

const thinkingLevelOrder: ReadonlyArray<string> = [
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max"
]

interface ModelValue {
  readonly value: string
}

export const sanitizeModelValue = (value: string): string =>
  value
    .replace(ansiEscapePattern, "")
    .replace(controlCharacterPattern, "")
    .replace(trailingSgrFragmentPattern, "")
    .trim()

export const findKnownModel = <Model extends ModelValue>(
  models: ReadonlyArray<Model>,
  value: string
): Model | undefined => {
  const exact = models.find((model) => model.value === value)
  if (exact !== undefined) return exact

  const sanitized = sanitizeModelValue(value)
  if (sanitized === value) return undefined
  return models.find((model) => model.value === sanitized)
}

export const highestThinkingLevel = (levels: ReadonlyArray<string>): string | undefined =>
  levels.reduce<string | undefined>((best, level) => {
    if (best === undefined) return level
    const rank = thinkingLevelOrder.indexOf(level)
    const bestRank = thinkingLevelOrder.indexOf(best)
    if (rank === -1 && bestRank !== -1) return best
    if (rank !== -1 && bestRank === -1) return level
    return rank >= bestRank ? level : best
  }, undefined)

/// Every value a picker option offers, flattening grouped entries.
export const offeredConfigValues = (option: SessionConfigOption): ReadonlySet<string> =>
  new Set(
    option.options.flatMap((entry) =>
      "value" in entry ? [entry.value] : entry.options.map((nested) => nested.value)
    )
  )

/// The value a requested or saved selection lands on in `option`: the value
/// itself when offered, else the provider's reconciliation of a drifted id
/// (Claude's Fable id changes between CLI releases) when that is offered.
/// `undefined` means the option cannot take it.
export const placeConfigValue = (
  option: SessionConfigOption,
  value: string,
  reconcile: ((option: SessionConfigOption, value: string) => string | undefined) | undefined
): string | undefined => {
  const offered = offeredConfigValues(option)
  if (offered.has(value)) return value
  const reconciled = reconcile?.(option, value)
  return reconciled !== undefined && offered.has(reconciled) ? reconciled : undefined
}
