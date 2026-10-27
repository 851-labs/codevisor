import type { ParseError, TypeError } from "@marcbachmann/cel-js"

export type CelError = ParseError | TypeError

export const describeCelError = (
  error: CelError | undefined,
  expression: string,
  fields: ReadonlyArray<string>
): string => {
  if (error === undefined) return "Filter is invalid."

  const located = `${error.summary}${locationOf(error, expression)}.`
  if (error.code !== "unknown_variable") return located
  return `${located} Fields: ${fields.join(", ")}.`
}

const locationOf = (error: CelError, expression: string): string => {
  if (error.range === undefined) return ""

  const snippet = expression.slice(error.range.start, error.range.end).trim()
  if (snippet === "") return ` at character ${error.range.start + 1}`
  return ` in "${snippet}"`
}
