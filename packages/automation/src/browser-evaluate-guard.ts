import { parseExpression } from "@babel/parser"

import { childNodes, evaluationLocals, type EvaluationLocals } from "./browser-evaluate-locals.js"
import { isRecord, recordOrEmpty, recordOrUndefined, type UnknownRecord } from "./unknown-values.js"

export const assertReadOnlyFunction = (source: string): void => {
  const expression = recordOrEmpty(parseEvaluationExpression(source))
  const locals = evaluationLocals(expression)
  const visit = (node: UnknownRecord): void => {
    assertReadOnlyNode(node, locals)
    for (const child of childNodes(node)) visit(child)
  }
  visit(expression)
  if (expression.type !== "FunctionExpression" && expression.type !== "ArrowFunctionExpression") {
    throw new Error("evaluate expects a function")
  }
}

const parseEvaluationExpression = (source: string): unknown => {
  try {
    return parseExpression(source, { plugins: ["typescript"], allowAwaitOutsideFunction: true })
  } catch (cause) {
    throw new Error(
      `evaluate expects a JavaScript function: ${cause instanceof Error ? cause.message : String(cause)}`,
      { cause }
    )
  }
}

const refusal = (what: string): Error =>
  new Error(`evaluate is read-only and rejects ${what}. Act on the page with locators instead.`)

const assertReadOnlyNode = (node: UnknownRecord, locals: EvaluationLocals): void => {
  if (node.type === "AssignmentExpression") assertOwnTarget(recordOrUndefined(node.left), locals)
  if (node.type === "UpdateExpression") assertOwnTarget(recordOrUndefined(node.argument), locals)
  if (node.type === "UnaryExpression" && node.operator === "delete") {
    if (!isOwnMember(recordOrUndefined(node.argument), locals)) throw refusal("delete")
  }
  if (node.type === "NewExpression") assertHarmlessConstructor(node)
  if (node.type === "CallExpression") assertReadOnlyCall(node, locals)
}

const assertOwnTarget = (target: UnknownRecord | undefined, locals: EvaluationLocals): void => {
  if (assignedPlaces(target).every((place) => isOwnPlace(place, locals))) return
  throw refusal("changing anything but its own local variables")
}

const assignedPlaces = (target: UnknownRecord | undefined): UnknownRecord[] => {
  if (target === undefined) return []
  if (target.type === "AssignmentPattern") return assignedPlaces(recordOrUndefined(target.left))
  if (target.type === "RestElement") return assignedPlaces(recordOrUndefined(target.argument))
  if (target.type === "ObjectProperty") return assignedPlaces(recordOrUndefined(target.value))
  if (target.type === "ArrayPattern") return patternPlaces(target.elements)
  if (target.type === "ObjectPattern") return patternPlaces(target.properties)
  return [target]
}

const patternPlaces = (items: unknown): UnknownRecord[] =>
  (Array.isArray(items) ? items : []).filter(isRecord).flatMap(assignedPlaces)

const isOwnPlace = (place: UnknownRecord, locals: EvaluationLocals): boolean => {
  if (place.type === "Identifier") return locals.declared.has(String(place.name))
  return isOwnMember(place, locals)
}

const isOwnMember = (target: UnknownRecord | undefined, locals: EvaluationLocals): boolean => {
  const object = recordOrUndefined(target?.object)
  return (
    target?.type === "MemberExpression" &&
    object?.type === "Identifier" &&
    locals.fresh.has(String(object.name))
  )
}

const sideEffectConstructors = new Set([
  "Audio",
  "BroadcastChannel",
  "EventSource",
  "Function",
  "Image",
  "Notification",
  "RTCPeerConnection",
  "SharedWorker",
  "WebSocket",
  "Worker",
  "XMLHttpRequest"
])

const assertHarmlessConstructor = (node: UnknownRecord): void => {
  const name = calledName(recordOrUndefined(node.callee))
  if (name !== undefined && sideEffectConstructors.has(name)) throw refusal(`new ${name}()`)
}

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

const sideEffectFunctions = new Set([
  "alert",
  "confirm",
  "print",
  "prompt",
  "pushState",
  "removeItem",
  "replaceState",
  "sendBeacon",
  "setItem"
])

const locationChanges = new Set(["assign", "reload", "replace"])

const assertReadOnlyCall = (node: UnknownRecord, locals: EvaluationLocals): void => {
  const callee = recordOrUndefined(node.callee)
  const name = calledName(callee)
  if (name === undefined) return
  if (name === "fetch") return assertReadOnlyFetch(node)
  if (sideEffectFunctions.has(name)) throw refusal(`${name}()`)
  if (locationChanges.has(name) && isLocation(recordOrUndefined(callee?.object)))
    throw refusal(`location.${name}()`)
  if (mutatingMethods.has(name) && callee?.type === "MemberExpression") {
    if (!isOwnMember(callee, locals)) throw refusal(`${name}()`)
  }
}

const calledName = (callee: UnknownRecord | undefined): string | undefined => {
  if (callee?.type === "Identifier") return String(callee.name)
  if (callee?.type !== "MemberExpression") return undefined
  const property = recordOrUndefined(callee.property)
  if (property?.type === "Identifier") return String(property.name)
  if (property?.type === "StringLiteral") return String(property.value)
  return undefined
}

const isLocation = (object: UnknownRecord | undefined): boolean => calledName(object) === "location"

const readOnlyMethods = new Set(["GET", "HEAD"])

const assertReadOnlyFetch = (node: UnknownRecord): void => {
  const [, options] = (Array.isArray(node.arguments) ? node.arguments : []).filter(isRecord)
  if (options === undefined) return
  if (options.type === "ObjectExpression" && readsOnly(options)) return
  throw refusal("fetch() with a method or body")
}

const readsOnly = (options: UnknownRecord): boolean =>
  (Array.isArray(options.properties) ? options.properties : [])
    .filter(isRecord)
    .every((property) => {
      const key = propertyKey(recordOrUndefined(property.key))
      if (property.type !== "ObjectProperty" || key === "body") return false
      if (key !== "method") return true
      const method = recordOrUndefined(property.value)
      return (
        method?.type === "StringLiteral" && readOnlyMethods.has(String(method.value).toUpperCase())
      )
    })

const propertyKey = (key: UnknownRecord | undefined): string => {
  if (key?.type === "Identifier") return String(key.name)
  if (key?.type === "StringLiteral") return String(key.value)
  return "body"
}
