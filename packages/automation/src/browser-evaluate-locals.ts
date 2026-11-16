import { isRecord, recordOrUndefined, type UnknownRecord } from "./unknown-values.js"

export interface EvaluationLocals {
  readonly declared: ReadonlySet<string>
  readonly fresh: ReadonlySet<string>
}

const literalTypes = new Set([
  "ObjectExpression",
  "ArrayExpression",
  "StringLiteral",
  "NumericLiteral",
  "BooleanLiteral",
  "NullLiteral",
  "BigIntLiteral",
  "RegExpLiteral",
  "TemplateLiteral",
  "NewExpression"
])

export const childNodes = (node: UnknownRecord): UnknownRecord[] =>
  Object.entries(node)
    .filter(([key]) => key !== "loc" && key !== "start" && key !== "end")
    .flatMap(([, value]) => (Array.isArray(value) ? value : [value]))
    .filter(isRecord)

export const evaluationLocals = (root: UnknownRecord): EvaluationLocals => {
  const declared = new Set<string>()
  const candidates = new Set<string>()
  const reused = new Set<string>()

  const visit = (node: UnknownRecord): void => {
    for (const name of declaredNames(node)) declared.add(name)
    const fresh = freshDeclaration(node)
    if (fresh !== undefined) candidates.add(fresh)
    for (const name of reusedNames(node)) reused.add(name)
    for (const child of childNodes(node)) visit(child)
  }
  visit(root)
  return { declared, fresh: new Set([...candidates].filter((name) => !reused.has(name))) }
}

export const isFreshValue = (node: UnknownRecord | undefined): boolean =>
  node === undefined || literalTypes.has(String(node.type))

const declaredNames = (node: UnknownRecord): string[] => {
  if (node.type === "VariableDeclarator") return bindingNames(recordOrUndefined(node.id))
  if (node.type === "CatchClause") return bindingNames(recordOrUndefined(node.param))
  if (isFunction(node)) return [...functionName(node), ...parameterNames(node)]
  return []
}

const isFunction = (node: UnknownRecord): boolean =>
  node.type === "FunctionExpression" ||
  node.type === "ArrowFunctionExpression" ||
  node.type === "FunctionDeclaration"

const functionName = (node: UnknownRecord): string[] => bindingNames(recordOrUndefined(node.id))

const parameterNames = (node: UnknownRecord): string[] =>
  (Array.isArray(node.params) ? node.params : []).filter(isRecord).flatMap(bindingNames)

const freshDeclaration = (node: UnknownRecord): string | undefined => {
  const id = recordOrUndefined(node.id)
  if (node.type !== "VariableDeclarator" || id?.type !== "Identifier") return undefined
  if (!isFreshValue(recordOrUndefined(node.init))) return undefined
  return String(id.name)
}

const reusedNames = (node: UnknownRecord): string[] => {
  if (node.type === "ForOfStatement" || node.type === "ForInStatement")
    return loopNames(recordOrUndefined(node.left))
  if (node.type !== "AssignmentExpression") return []
  const left = recordOrUndefined(node.left)
  if (left?.type !== "Identifier" || isFreshValue(recordOrUndefined(node.right))) return []
  return [String(left.name)]
}

const loopNames = (left: UnknownRecord | undefined): string[] => {
  if (left?.type !== "VariableDeclaration") return bindingNames(left)
  return (Array.isArray(left.declarations) ? left.declarations : [])
    .filter(isRecord)
    .flatMap((declarator) => bindingNames(recordOrUndefined(declarator.id)))
}

const bindingNames = (pattern: UnknownRecord | undefined): string[] => {
  if (pattern === undefined) return []
  if (pattern.type === "Identifier") return [String(pattern.name)]
  if (pattern.type === "AssignmentPattern") return bindingNames(recordOrUndefined(pattern.left))
  if (pattern.type === "RestElement") return bindingNames(recordOrUndefined(pattern.argument))
  if (pattern.type === "ObjectProperty") return bindingNames(recordOrUndefined(pattern.value))
  if (pattern.type === "ArrayPattern") return patternItems(pattern.elements)
  if (pattern.type === "ObjectPattern") return patternItems(pattern.properties)
  return []
}

const patternItems = (items: unknown): string[] =>
  (Array.isArray(items) ? items : []).filter(isRecord).flatMap(bindingNames)
