import { exemptionTracker } from "./exemptions.mjs"

const sqlMethods = new Set(["prepare", "exec", "run", "query"])
const sqlStart =
  /^\s*(?:select|insert|update|delete|replace|create|drop|alter|pragma|with|begin|commit|rollback|savepoint|release|attach|detach|vacuum|analyze|reindex)\b/i

function literalText(node) {
  if (node.type === "Literal") return typeof node.value === "string" ? node.value : undefined
  if (node.type === "TemplateLiteral") return node.quasis.map((quasi) => quasi.value.raw).join("")
  if (node.type === "BinaryExpression" && node.operator === "+") return literalText(node.left)
  return undefined
}

const calledMethod = (node) => {
  const { callee } = node
  if (callee.type !== "MemberExpression" || callee.computed) return undefined
  return callee.property.name
}

const isSqlLiteral = (node) => node !== undefined && sqlStart.test(literalText(node) ?? "")

export const namedSql = (exemptions) => ({
  create(context) {
    const tracker = exemptionTracker(context, exemptions)
    return {
      CallExpression(node) {
        if (!sqlMethods.has(calledMethod(node))) return
        const [query] = node.arguments
        if (!isSqlLiteral(query) || tracker.isExempt(query)) return
        context.report({
          node: query,
          message: `Name this query: move the SQL into a module-level constant and pass that to .${calledMethod(node)}().`
        })
      },
      "Program:exit"() {
        tracker.reportStale()
      }
    }
  }
})
