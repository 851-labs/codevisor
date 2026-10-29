import { resolve } from "node:path"

interface ToolResultEvent {
  readonly isError: boolean
  readonly toolName: string
  readonly input: { readonly path?: string }
  readonly content: ReadonlyArray<unknown>
}

interface ExtensionContext {
  readonly cwd: string
  readonly signal?: AbortSignal
}

interface ExecResult {
  readonly code: number
  readonly stdout: string
}

interface ExtensionApi {
  readonly on: (
    event: "tool_result",
    handler: (
      event: ToolResultEvent,
      ctx: ExtensionContext
    ) => Promise<{ content: ReadonlyArray<unknown> } | undefined>
  ) => void
  readonly exec: (
    command: string,
    args: ReadonlyArray<string>,
    options: { cwd: string; timeout: number; signal?: AbortSignal }
  ) => Promise<ExecResult>
}

const root = resolve(import.meta.dirname, "../..")

export default function formatLint(pi: ExtensionApi): void {
  pi.on("tool_result", async (event, ctx) => {
    if (event.isError || (event.toolName !== "edit" && event.toolName !== "write")) return undefined
    if (event.input.path === undefined) return undefined
    const file = resolve(ctx.cwd, event.input.path)
    const check = await pi.exec(resolve(root, "scripts/agent-hooks/check-files.sh"), [file], {
      cwd: root,
      timeout: 60_000,
      ...(ctx.signal === undefined ? {} : { signal: ctx.signal })
    })
    if (check.code === 0) return undefined
    return {
      content: [
        ...event.content,
        {
          type: "text",
          text: `Formatted the edited file(s). Lint errors to fix now:\n${check.stdout}`
        }
      ]
    }
  })
}
