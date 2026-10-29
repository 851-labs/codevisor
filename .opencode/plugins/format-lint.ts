import { spawnSync } from "node:child_process"
import path from "node:path"
import { fileURLToPath } from "node:url"

interface EditInput {
  readonly path?: string
  readonly patchText?: string
}

interface ToolResult {
  content: ReadonlyArray<unknown>
}

interface ToolEvent {
  readonly status: string
  readonly tool: string
  readonly input: EditInput
  readonly result: ToolResult
}

interface PluginContext {
  readonly tool: {
    readonly hook: (
      name: "execute.after",
      handler: (event: ToolEvent) => Promise<void>
    ) => Promise<unknown>
  }
}

const root = fileURLToPath(new URL("../..", import.meta.url))
const editTools = new Set(["edit", "write", "patch"])

const editedFiles = (input: EditInput): ReadonlyArray<string> => {
  if (input.path !== undefined) return [path.resolve(root, input.path)]
  return [...(input.patchText ?? "").matchAll(/^\*\*\* (?:Add|Update) File: (.+)$/gm)].map(
    (match) => path.resolve(root, match[1] ?? "")
  )
}

export default {
  id: "codevisor.format-lint",
  setup: async (ctx: PluginContext) => {
    await ctx.tool.hook("execute.after", async (event) => {
      if (event.status !== "completed" || !editTools.has(event.tool)) return
      const check = spawnSync(
        path.join(root, "scripts/agent-hooks/check-files.sh"),
        editedFiles(event.input),
        { cwd: root, encoding: "utf8" }
      )
      if (check.status === 0) return
      event.result.content = [
        ...event.result.content,
        {
          type: "text",
          text: `Formatted the edited file(s). Lint errors to fix now:\n${check.stdout}`
        }
      ]
    })
  }
}
