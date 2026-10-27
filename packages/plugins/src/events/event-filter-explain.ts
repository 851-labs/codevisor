import { parse, serialize, type ASTNode } from "@marcbachmann/cel-js"

export const everyEvent = "every event"

export const explainEventFilter = (expression: string | undefined): string => {
  const text = expression?.trim() ?? ""
  if (text === "") return everyEvent

  try {
    return explainNode(parse(text).ast)
  } catch {
    return text
  }
}

export const explainNode = (node: ASTNode): string => {
  switch (node.op) {
    case "&&":
      return joined(node.args, "&&", "and")
    case "||":
      return joined(node.args, "||", "or")
    case "!_":
      return negated(node.args)
    case "in":
      return membership(node.args[0], node.args[1], affirmative)
    case "==":
    case "!=":
    case "<":
    case "<=":
    case ">":
    case ">=":
      return node.args.map(serialize).join(` ${comparisons[node.op]} `)
    case "rcall":
      return methodPhrase(node) ?? serialize(node)
    case "call":
      return presencePhrase(node) ?? serialize(node)
    default:
      return serialize(node)
  }
}

interface MembershipPhrases {
  readonly single: string
  readonly oneOf: string
  readonly contains: string
}

const affirmative: MembershipPhrases = { single: "is", oneOf: "is one of", contains: "contains" }

const negative: MembershipPhrases = {
  single: "is not",
  oneOf: "is not one of",
  contains: "does not contain"
}

const comparisons = {
  "==": "is",
  "!=": "is not",
  "<": "is less than",
  "<=": "is at most",
  ">": "is greater than",
  ">=": "is at least"
}

const methods: Readonly<Record<string, string>> = {
  contains: "contains",
  endsWith: "ends with",
  matches: "matches the pattern",
  startsWith: "starts with"
}

const joined = (sides: ReadonlyArray<ASTNode>, op: "&&" | "||", word: string): string =>
  sides.map((side) => grouped(side, op)).join(` ${word} `)

const grouped = (side: ASTNode, op: "&&" | "||"): string => {
  const text = explainNode(side)
  if (isOtherLogic(side, op)) return `(${text})`
  return text
}

const isOtherLogic = (node: ASTNode, op: "&&" | "||"): boolean =>
  (node.op === "&&" || node.op === "||") && node.op !== op

const negated = (node: ASTNode): string => {
  if (node.op === "in") return membership(node.args[0], node.args[1], negative)
  return `not (${explainNode(node)})`
}

const membership = (item: ASTNode, collection: ASTNode, phrases: MembershipPhrases): string => {
  if (collection.op !== "list")
    return `${serialize(collection)} ${phrases.contains} ${serialize(item)}`

  const choices = collection.args.map(serialize)
  if (choices.length === 1) return `${serialize(item)} ${phrases.single} ${choices.join("")}`
  return `${serialize(item)} ${phrases.oneOf} ${listed(choices)}`
}

const listed = (items: ReadonlyArray<string>): string => {
  if (items.length === 0) return "nothing"
  return `${items.slice(0, -1).join(", ")} or ${items.slice(-1).join("")}`
}

const methodPhrase = (node: Extract<ASTNode, { op: "rcall" }>): string | undefined => {
  const [name, receiver, args] = node.args
  const phrase = methods[name]
  if (phrase === undefined || args.length !== 1) return undefined
  return `${serialize(receiver)} ${phrase} ${args.map(serialize).join("")}`
}

const presencePhrase = (node: Extract<ASTNode, { op: "call" }>): string | undefined => {
  const [name, args] = node.args
  if (name !== "has" || args.length !== 1) return undefined
  return `${args.map(serialize).join("")} is set`
}
