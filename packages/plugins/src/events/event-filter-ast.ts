import type { ASTNode } from "@marcbachmann/cel-js"

export const childrenOf = (node: ASTNode): ReadonlyArray<ASTNode> => {
  switch (node.op) {
    case "value":
    case "id":
      return []
    case ".":
    case ".?":
      return [node.args[0]]
    case "!_":
    case "-_":
      return [node.args]
    case "call":
      return node.args[1]
    case "rcall":
      return [node.args[1], ...node.args[2]]
    case "map":
      return node.args.flat()
    default:
      return node.args
  }
}

export interface Comprehension {
  readonly range: ASTNode
  readonly body: ReadonlyArray<ASTNode>
}

export const comprehensionOf = (node: ASTNode): Comprehension | undefined => {
  if (node.op !== "rcall" || !comprehensionMacros.has(node.args[0])) return undefined
  return { range: node.args[1], body: node.args[2] }
}

export const regexPatternOf = (node: ASTNode): ASTNode | undefined => {
  if (node.op !== "rcall" || node.args[0] !== "matches") return undefined
  return node.args[2][0]
}

const comprehensionMacros = new Set(["all", "exists", "exists_one", "filter", "map"])
