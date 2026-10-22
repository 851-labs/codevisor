import { exemptionTracker } from "./exemptions.mjs"

const effectTypes = new Set(["AwaitExpression", "YieldExpression", "AssignmentExpression"])
const scopeTypes = new Set([
  "ArrowFunctionExpression",
  "FunctionExpression",
  "FunctionDeclaration",
  "ClassExpression",
  "ClassDeclaration"
])
const skippedKeys = new Set(["parent", "loc", "range", "start", "end"])

const isNode = (value) => typeof value?.type === "string"

const children = (node) =>
  Object.entries(node)
    .filter(([key]) => !skippedKeys.has(key))
    .flatMap(([, value]) => (Array.isArray(value) ? value : [value]))
    .filter(isNode)

function findEffect(node) {
  if (effectTypes.has(node.type)) return node
  if (scopeTypes.has(node.type)) return undefined
  for (const child of children(node)) {
    const effect = findEffect(child)
    if (effect !== undefined) return effect
  }
  return undefined
}

function isDiscarded(node) {
  const { parent } = node
  if (parent.type === "ExpressionStatement") return true
  if (parent.type === "UnaryExpression") return parent.operator === "void"
  if (parent.type !== "SequenceExpression") return false
  return parent.expressions.at(-1) !== node || isDiscarded(parent)
}

const effectNames = {
  AwaitExpression: "an await",
  YieldExpression: "a yield",
  AssignmentExpression: "an assignment"
}

function problem(node) {
  if (isDiscarded(node)) {
    return "This ternary's value is discarded, so it chooses between code paths. Use an if."
  }
  const effect = findEffect(node.consequent) ?? findEffect(node.alternate)
  if (effect === undefined) return undefined
  return `This ternary runs ${effectNames[effect.type]} in a branch. Use an if, so a ternary only picks a value.`
}

export const noEffectTernary = (exemptions) => ({
  create(context) {
    const tracker = exemptionTracker(context, exemptions)
    return {
      ConditionalExpression(node) {
        const message = problem(node)
        if (message === undefined || tracker.isExempt(node)) return
        context.report({ node, message })
      },
      "Program:exit"() {
        tracker.reportStale()
      }
    }
  }
})
