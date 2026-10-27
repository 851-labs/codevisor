import type { ASTNode } from "@marcbachmann/cel-js"

import { childrenOf, comprehensionOf, regexPatternOf } from "./event-filter-ast.js"
import { patternProblem } from "./event-filter-regex.js"

export const maxComprehensionDepth = 2

export const guardProblem = (ast: ASTNode): string | undefined => problemAt(ast, 0)

const problemAt = (node: ASTNode, depth: number): string | undefined => {
  const regexProblem = regexProblemOf(node)
  if (regexProblem !== undefined) return regexProblem

  const comprehension = comprehensionOf(node)
  if (comprehension === undefined) return firstProblem(childrenOf(node), depth)
  if (depth >= maxComprehensionDepth)
    return `Filters can nest at most ${maxComprehensionDepth} list macros.`

  return firstProblem([comprehension.range], depth) ?? firstProblem(comprehension.body, depth + 1)
}

const firstProblem = (children: ReadonlyArray<ASTNode>, depth: number): string | undefined => {
  for (const child of children) {
    const problem = problemAt(child, depth)
    if (problem !== undefined) return problem
  }
  return undefined
}

const regexProblemOf = (node: ASTNode): string | undefined => {
  const pattern = regexPatternOf(node)
  if (pattern === undefined) return undefined
  if (pattern.op !== "value" || typeof pattern.args !== "string")
    return "matches() needs a quoted pattern."

  const problem = patternProblem(pattern.args)
  if (problem === undefined) return undefined
  return `The matches() pattern ${problem}.`
}
