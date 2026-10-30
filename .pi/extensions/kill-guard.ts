import { spawnSync } from "node:child_process"
import { resolve } from "node:path"

interface ToolCallEvent {
  readonly toolName: string
  readonly input: { readonly command?: unknown }
}

interface ToolCallBlock {
  readonly block: true
  readonly reason: string
}

interface ExtensionApi {
  readonly on: (
    event: "tool_call",
    handler: (event: ToolCallEvent) => Promise<ToolCallBlock | undefined>
  ) => void
}

const guard = resolve(import.meta.dirname, "../../scripts/agent-hooks/kill-guard.mjs")
const blockedExitCode = 2

export default function killGuard(pi: ExtensionApi): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return undefined
    const check = spawnSync(guard, [], {
      input: JSON.stringify({ tool_input: event.input }),
      encoding: "utf8"
    })
    if (check.status !== blockedExitCode) return undefined
    return { block: true, reason: check.stderr.trim() }
  })
}
