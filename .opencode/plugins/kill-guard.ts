import { spawnSync } from "node:child_process"
import { fileURLToPath } from "node:url"

interface ShellInput {
  readonly command?: unknown
}

interface ToolEvent {
  readonly tool: string
  readonly input: ShellInput
}

interface PluginContext {
  readonly tool: {
    readonly hook: (
      name: "execute.before",
      handler: (event: ToolEvent) => Promise<void>
    ) => Promise<unknown>
  }
}

const guard = fileURLToPath(new URL("../../scripts/agent-hooks/kill-guard.mjs", import.meta.url))
const shellTools = new Set(["shell", "bash"])
const blockedExitCode = 2

export default {
  id: "codevisor.kill-guard",
  setup: async (ctx: PluginContext) => {
    await ctx.tool.hook("execute.before", async (event) => {
      if (!shellTools.has(event.tool)) return
      const check = spawnSync(guard, [], {
        input: JSON.stringify({ tool_input: event.input }),
        encoding: "utf8"
      })
      if (check.status === blockedExitCode) throw new Error(check.stderr.trim())
    })
  }
}
