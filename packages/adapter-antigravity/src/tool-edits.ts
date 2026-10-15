import { diffStatsFromTexts } from "@codevisor/agent-runtime"

import { param, record, text } from "./protocol.js"

const EDIT_TOOLS = new Set(["write_to_file", "replace_file_content", "multi_replace_file_content"])

const replacementChunks = (parameters: Record<string, unknown>) => {
  const listed = param(parameters, "ReplacementChunks")
  return (Array.isArray(listed) ? listed : [parameters]).flatMap((entry) => {
    const chunk = record(entry)
    const newText = param(chunk, "ReplacementContent")
    if (typeof newText !== "string") return []
    const oldText = param(chunk, "TargetContent")
    return [{ oldText: typeof oldText === "string" ? oldText : null, newText }]
  })
}

const replacementDiff = (path: string, chunks: ReturnType<typeof replacementChunks>) => {
  const stats = chunks.map((chunk) => diffStatsFromTexts(path, chunk.oldText, chunk.newText))
  return {
    content: chunks.map((chunk) => ({ type: "diff", path, ...chunk })),
    diffStats: [
      {
        path,
        added: stats.reduce((sum, stat) => sum + stat.added, 0),
        removed: stats.reduce((sum, stat) => sum + stat.removed, 0)
      }
    ]
  }
}

export const fileChange = (tool: string, parameters: Record<string, unknown>) => {
  const path = text(param(parameters, "TargetFile", "AbsolutePath"))
  if (path === undefined || !EDIT_TOOLS.has(tool)) return undefined
  const whole = param(parameters, "CodeContent")
  if (typeof whole === "string")
    return {
      content: [{ type: "diff", path, oldText: null, newText: whole }],
      diffStats: [diffStatsFromTexts(path, undefined, whole)]
    }
  const chunks = replacementChunks(parameters)
  if (chunks.length === 0) return undefined
  return replacementDiff(path, chunks)
}
