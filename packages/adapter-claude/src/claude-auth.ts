import { query, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk"

import { isRecord } from "./internal.js"

export interface ClaudeAuthClient {
  readonly start: () => Promise<{ readonly url: string }>
  readonly submit: (pasted: string) => Promise<void>
  readonly close: () => void
}

export interface ClaudeAuthSpawn {
  readonly claudePath: string
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
  readonly queryFn?: (input: Parameters<typeof query>[0]) => object
}

interface ClaudeAuthControl {
  claudeAuthenticate(loginWithClaudeAi: boolean): Promise<unknown>
  claudeOAuthCallback(code: string, state: string): Promise<unknown>
  interrupt(): Promise<unknown>
  close(): void
}

const CONTROL_METHODS = ["claudeAuthenticate", "claudeOAuthCallback", "interrupt", "close"]

const isClaudeAuthControl = (value: object): value is ClaudeAuthControl =>
  CONTROL_METHODS.every((name) => typeof Reflect.get(value, name) === "function")

const pendingPrompt: AsyncIterable<SDKUserMessage> = {
  [Symbol.asyncIterator]: () => ({ next: () => new Promise(() => {}) })
}

const stringField = (fields: Record<string, unknown>, key: string): string | undefined => {
  const value = fields[key]
  return typeof value === "string" ? value : undefined
}

export const spawnClaudeAuthClient = (spawn: ClaudeAuthSpawn): ClaudeAuthClient => {
  const control = (spawn.queryFn ?? query)({
    prompt: pendingPrompt,
    options: {
      cwd: spawn.cwd,
      env: spawn.env,
      pathToClaudeCodeExecutable: spawn.claudePath
    }
  })
  if (!isClaudeAuthControl(control)) throw new Error("Claude does not support signing in")
  return {
    start: async () => {
      const response = await control.claudeAuthenticate(true)
      const fields = isRecord(response) ? response : {}
      const url = stringField(fields, "manualUrl") ?? stringField(fields, "automaticUrl")
      if (url === undefined) throw new Error("Claude did not provide a sign-in URL")
      return { url }
    },
    submit: async (pasted) => {
      const [code, state] = pasted.trim().split("#", 2)
      if (!code) throw new Error("Paste the code from Claude's sign-in page")
      await control.claudeOAuthCallback(code, state ?? "")
    },
    close: () => {
      void control.interrupt().catch(() => undefined)
      control.close()
    }
  }
}
