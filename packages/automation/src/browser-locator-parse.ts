/// Locator descriptors as tools send them, validated into the internal shape.

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

const parseTextMatcher = (value: unknown, label: string): BrowserTextMatcher => {
  if (typeof value === "string") return value
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be a string or regular expression`)
  }
  const input = value as Readonly<Record<string, unknown>>
  if (
    typeof input.regex !== "string" ||
    (input.flags !== undefined && typeof input.flags !== "string")
  ) {
    throw new Error(`${label} must contain regex and optional flags strings`)
  }
  try {
    new RegExp(input.regex, input.flags)
  } catch (cause) {
    throw new Error(
      `${label} is invalid: ${cause instanceof Error ? cause.message : String(cause)}`
    )
  }
  return {
    regex: input.regex,
    ...(typeof input.flags === "string" ? { flags: input.flags } : {})
  }
}

export const parseLocator = (value: unknown, depth = 0): BrowserLocator => {
  if (depth > 12) throw new Error("locator composition is too deeply nested")
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("locator must be a Playwright-style locator object")
  }
  const locator = value as Readonly<Record<string, unknown>>
  const modes = ["ref", "css", "role", "label", "placeholder", "text", "testId"].filter((key) => {
    const candidate = locator[key]
    return typeof candidate === "string"
      ? candidate.length > 0
      : ["label", "placeholder", "text"].includes(key) &&
          candidate !== null &&
          typeof candidate === "object"
  })
  if (modes.length !== 1) {
    throw new Error(
      "locator must contain exactly one of ref, css, role, label, placeholder, text, or testId"
    )
  }
  if (locator.role === undefined && locator.name !== undefined) {
    throw new Error("locator.name is only valid with locator.role")
  }
  if (
    locator.frame !== undefined &&
    (!Array.isArray(locator.frame) ||
      !locator.frame.every((selector) => typeof selector === "string" && selector.length > 0))
  ) {
    throw new Error("locator.frame must be an array of frame selectors")
  }
  if (
    locator.index !== undefined &&
    locator.index !== "last" &&
    (typeof locator.index !== "number" || !Number.isInteger(locator.index) || locator.index < 0)
  ) {
    throw new Error("locator.index must be a non-negative integer or last")
  }
  const scope = locator.scope === undefined ? undefined : parseLocator(locator.scope, depth + 1)
  const and = locator.and === undefined ? undefined : parseLocator(locator.and, depth + 1)
  const or = locator.or === undefined ? undefined : parseLocator(locator.or, depth + 1)
  let filters: BrowserLocator["filters"]
  if (locator.filters !== undefined) {
    if (
      locator.filters === null ||
      typeof locator.filters !== "object" ||
      Array.isArray(locator.filters)
    ) {
      throw new Error("locator.filters must be an object")
    }
    const input = locator.filters as Readonly<Record<string, unknown>>
    if (input.visible !== undefined && typeof input.visible !== "boolean") {
      throw new Error("locator.filters.visible must be a boolean")
    }
    filters = {
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
  return {
    ...(locator.ref === undefined ? {} : { ref: String(locator.ref) }),
    ...(locator.css === undefined ? {} : { css: String(locator.css) }),
    ...(locator.role === undefined ? {} : { role: String(locator.role) }),
    ...(locator.name === undefined ? {} : { name: parseTextMatcher(locator.name, "locator.name") }),
    ...(locator.label === undefined
      ? {}
      : { label: parseTextMatcher(locator.label, "locator.label") }),
    ...(locator.placeholder === undefined
      ? {}
      : { placeholder: parseTextMatcher(locator.placeholder, "locator.placeholder") }),
    ...(locator.text === undefined ? {} : { text: parseTextMatcher(locator.text, "locator.text") }),
    ...(locator.testId === undefined ? {} : { testId: String(locator.testId) }),
    ...(locator.exact === true ? { exact: true } : {}),
    ...(scope === undefined ? {} : { scope }),
    ...(locator.frame === undefined ? {} : { frame: locator.frame as string[] }),
    ...(filters === undefined ? {} : { filters }),
    ...(locator.index === undefined ? {} : { index: locator.index as number | "last" }),
    ...(and === undefined ? {} : { and }),
    ...(or === undefined ? {} : { or })
  }
}
