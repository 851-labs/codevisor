import { parseExpression } from "@babel/parser"

import { isRecord, recordOrEmpty, recordOrUndefined, type UnknownRecord } from "./unknown-values.js"

const parseEvaluationExpression = (source: string): unknown => {
  let expression: unknown
  try {
    expression = parseExpression(source, {
      plugins: ["typescript"],
      allowAwaitOutsideFunction: true
    })
  } catch (cause) {
    throw new Error(
      `evaluate expects a JavaScript function: ${cause instanceof Error ? cause.message : String(cause)}`,
      { cause }
    )
  }
  return expression
}

const calledPropertyName = (property: UnknownRecord | undefined) => {
  if (property?.type === "Identifier") return property.name
  if (property?.type === "StringLiteral") return property.value
  return undefined
}

const assertReadOnlyNode = (
  candidate: Readonly<Record<string, unknown>>,
  mutatingMethods: ReadonlySet<string>
): void => {
  const type = candidate.type
  if (type === "AssignmentExpression" || type === "UpdateExpression" || type === "NewExpression") {
    throw new Error("evaluate is read-only and rejects assignment, update, and construction")
  }
  if (type === "UnaryExpression" && candidate.operator === "delete") {
    throw new Error("evaluate is read-only and rejects delete")
  }
  if (type === "CallExpression") {
    const callee = recordOrUndefined(candidate.callee)
    const property =
      callee?.type === "MemberExpression" ? recordOrUndefined(callee.property) : undefined
    const name = calledPropertyName(property)
    if (typeof name === "string" && mutatingMethods.has(name)) {
      throw new Error(`evaluate is read-only and rejects ${name}()`)
    }
  }
}

export const assertReadOnlyFunction = (source: string): void => {
  const expression = parseEvaluationExpression(source)
  const mutatingMethods = new Set([
    "append",
    "appendChild",
    "before",
    "blur",
    "click",
    "close",
    "dispatchEvent",
    "focus",
    "insertAdjacentElement",
    "insertAdjacentHTML",
    "insertAdjacentText",
    "insertBefore",
    "open",
    "postMessage",
    "prepend",
    "remove",
    "removeAttribute",
    "removeChild",
    "replaceChildren",
    "replaceWith",
    "requestSubmit",
    "setAttribute",
    "submit",
    "write",
    "writeln"
  ])
  const seen = new WeakSet<object>()
  const visit = (node: unknown): void => {
    if (!isRecord(node) || seen.has(node)) return
    seen.add(node)
    assertReadOnlyNode(node, mutatingMethods)
    for (const [key, value] of Object.entries(node)) {
      if (key === "loc" || key === "start" || key === "end") continue
      if (Array.isArray(value)) {
        for (const item of value) visit(item)
      } else visit(value)
    }
  }
  visit(expression)
  const type = recordOrEmpty(expression).type
  if (type !== "FunctionExpression" && type !== "ArrowFunctionExpression") {
    throw new Error("evaluate expects a function")
  }
}
