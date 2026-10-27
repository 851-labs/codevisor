import {
  Environment,
  type Limits,
  type ParseResult,
  type TypeCheckResult
} from "@marcbachmann/cel-js"

import { describeCelError } from "./event-filter-errors.js"
import { everyEvent, explainNode } from "./event-filter-explain.js"
import { guardProblem } from "./event-filter-guards.js"
import { shapeOfSchema } from "./event-filter-shape.js"
import {
  filterVariablesFor,
  type EventFilterContext,
  type FilterVariables
} from "./event-filter-variables.js"

export interface CompiledEventFilter {
  readonly expression: string
  readonly matches: (payload: unknown, context: EventFilterContext) => boolean
}

export interface EventFilterAccepted {
  readonly ok: true
  readonly filter: CompiledEventFilter
  readonly explained: string
}

export interface EventFilterRejected {
  readonly ok: false
  readonly error: string
}

export type EventFilterCompilation = EventFilterAccepted | EventFilterRejected

export const maxEventFilterLength = 2000

export const compileEventFilter = (
  expression: string | undefined,
  payloadSchema: unknown
): EventFilterCompilation => {
  const text = expression?.trim() ?? ""
  if (text === "") return accepted(matchEverything, everyEvent)
  if (text.length > maxEventFilterLength) return rejected(tooLong(text))

  const variables = filterVariablesFor(shapeOfSchema(payloadSchema))
  const scope = filterScope(variables)
  const typeProblem = typeProblemOf(scope.env.check(text), text, scope.names)
  if (typeProblem !== undefined) return rejected(typeProblem)

  const parsed = scope.env.parse(text)
  const guard = guardProblem(parsed.ast)
  if (guard !== undefined) return rejected(guard)

  return accepted(filterOf(text, parsed, variables), explainNode(parsed.ast))
}

interface FilterScope {
  readonly env: Environment
  readonly names: ReadonlyArray<string>
}

const filterLimits: Limits = {
  maxAstNodes: 1000,
  maxDepth: 32,
  maxListElements: 100,
  maxMapEntries: 100,
  maxCallArguments: 8
}

const matchEverything: CompiledEventFilter = { expression: "", matches: () => true }

const accepted = (filter: CompiledEventFilter, explained: string): EventFilterAccepted => ({
  ok: true,
  filter,
  explained
})

const rejected = (error: string): EventFilterRejected => ({ ok: false, error })

const tooLong = (text: string): string =>
  `Filter is too long (${text.length} characters, at most ${maxEventFilterLength}).`

const filterScope = (variables: FilterVariables): FilterScope => {
  const env = new Environment({
    unlistedVariablesAreDyn: variables.unlistedAreDyn,
    limits: filterLimits
  })
  return { env, names: variables.declare(env) }
}

const typeProblemOf = (
  check: TypeCheckResult,
  text: string,
  names: ReadonlyArray<string>
): string | undefined => {
  if (!check.valid) return describeCelError(check.error, text, names)
  if (check.type !== "bool") return `Filter must be true or false, but it gives ${check.type}.`
  return undefined
}

const filterOf = (
  expression: string,
  result: ParseResult,
  variables: FilterVariables
): CompiledEventFilter => ({
  expression,
  matches: (payload, context) => evaluatesTrue(result, variables.activation(payload, context))
})

const evaluatesTrue = (result: ParseResult, activation: Record<string, unknown>): boolean => {
  try {
    return result(activation) === true
  } catch {
    return false
  }
}
