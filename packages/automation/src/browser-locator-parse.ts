import { isPlainRecord, isStringArray } from "./unknown-values.js"

interface BrowserLocator {
  readonly ref?: string
  readonly css?: string
  readonly role?: string
  readonly name?: BrowserTextMatcher
  readonly label?: BrowserTextMatcher
  readonly placeholder?: BrowserTextMatcher
  readonly text?: BrowserTextMatcher
  readonly testId?: string
  readonly exact?: boolean
  readonly scope?: BrowserLocator
  readonly frame?: ReadonlyArray<string>
  readonly filters?: {
    readonly has?: BrowserLocator
    readonly hasNot?: BrowserLocator
    readonly hasText?: BrowserTextMatcher
    readonly hasNotText?: BrowserTextMatcher
    readonly visible?: boolean
  }
  readonly index?: number | "last"
  readonly and?: BrowserLocator
  readonly or?: BrowserLocator
}

type BrowserTextMatcher = string | { readonly regex: string; readonly flags?: string }

const parseTextMatcher = (input: unknown, label: string): BrowserTextMatcher => {
  if (typeof input === "string") return input
  if (!isPlainRecord(input)) throw new Error(`${label} must be a string or regular expression`)
  if (
    typeof input.regex !== "string" ||
    (input.flags !== undefined && typeof input.flags !== "string")
  ) {
    throw new Error(`${label} must contain regex and optional flags strings`)
  }
  try {
    // oxlint-disable-next-line no-new
    new RegExp(input.regex, input.flags)
  } catch (cause) {
    throw new Error(
      `${label} is invalid: ${cause instanceof Error ? cause.message : String(cause)}`,
      { cause }
    )
  }
  return {
    regex: input.regex,
    ...(typeof input.flags === "string" ? { flags: input.flags } : {})
  }
}

const validateLocatorDescriptor = (locator: Readonly<Record<string, unknown>>): void => {
  const modes = ["ref", "css", "role", "label", "placeholder", "text", "testId"].filter((key) => {
    const candidate = locator[key]
    if (typeof candidate === "string") return candidate.length > 0
    return (
      ["label", "placeholder", "text"].includes(key) &&
      candidate !== null &&
      typeof candidate === "object"
    )
  })
  if (modes.length !== 1) {
    throw new Error(
      "locator must contain exactly one of ref, css, role, label, placeholder, text, or testId"
    )
  }
  if (locator.role === undefined && locator.name !== undefined) {
    throw new Error("locator.name is only valid with locator.role")
  }
}

const parseLocatorFrame = (value: unknown): ReadonlyArray<string> | undefined => {
  if (value === undefined) return undefined
  if (!isStringArray(value) || !value.every((selector) => selector.length > 0)) {
    throw new Error("locator.frame must be an array of frame selectors")
  }
  return value
}

const parseLocatorIndex = (value: unknown): number | "last" | undefined => {
  if (value === undefined || value === "last") return value
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0) {
    throw new Error("locator.index must be a non-negative integer or last")
  }
  return value
}

const parseLocatorFilters = (
  locator: Readonly<Record<string, unknown>>,
  depth: number
): BrowserLocator["filters"] => {
  if (locator.filters === undefined) return undefined
  if (!isPlainRecord(locator.filters)) throw new Error("locator.filters must be an object")
  const input = locator.filters
  if (input.visible !== undefined && typeof input.visible !== "boolean") {
    throw new Error("locator.filters.visible must be a boolean")
  }
  return {
    ...(input.has === undefined ? {} : { has: parseLocator(input.has, depth + 1) }),
    ...(input.hasNot === undefined ? {} : { hasNot: parseLocator(input.hasNot, depth + 1) }),
    ...(input.hasText === undefined
      ? {}
      : { hasText: parseTextMatcher(input.hasText, "locator.filters.hasText") }),
    ...(input.hasNotText === undefined
      ? {}
      : { hasNotText: parseTextMatcher(input.hasNotText, "locator.filters.hasNotText") }),
    ...(typeof input.visible === "boolean" ? { visible: input.visible } : {})
  }
}

export const parseLocator = (locator: unknown, depth = 0): BrowserLocator => {
  if (depth > 12) throw new Error("locator composition is too deeply nested")
  if (!isPlainRecord(locator)) throw new Error("locator must be a Playwright-style locator object")
  validateLocatorDescriptor(locator)
  const frame = parseLocatorFrame(locator.frame)
  const index = parseLocatorIndex(locator.index)
  const scope = locator.scope === undefined ? undefined : parseLocator(locator.scope, depth + 1)
  const and = locator.and === undefined ? undefined : parseLocator(locator.and, depth + 1)
  const or = locator.or === undefined ? undefined : parseLocator(locator.or, depth + 1)
  const filters = parseLocatorFilters(locator, depth)
  return {
    ...(typeof locator.ref === "string" ? { ref: locator.ref } : {}),
    ...(typeof locator.css === "string" ? { css: locator.css } : {}),
    ...(typeof locator.role === "string" ? { role: locator.role } : {}),
    ...(locator.name === undefined ? {} : { name: parseTextMatcher(locator.name, "locator.name") }),
    ...(locator.label === undefined
      ? {}
      : { label: parseTextMatcher(locator.label, "locator.label") }),
    ...(locator.placeholder === undefined
      ? {}
      : { placeholder: parseTextMatcher(locator.placeholder, "locator.placeholder") }),
    ...(locator.text === undefined ? {} : { text: parseTextMatcher(locator.text, "locator.text") }),
    ...(typeof locator.testId === "string" ? { testId: locator.testId } : {}),
    ...(locator.exact === true ? { exact: true } : {}),
    ...(scope === undefined ? {} : { scope }),
    ...(frame === undefined ? {} : { frame }),
    ...(filters === undefined ? {} : { filters }),
    ...(index === undefined ? {} : { index }),
    ...(and === undefined ? {} : { and }),
    ...(or === undefined ? {} : { or })
  }
}
