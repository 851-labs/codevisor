import { query } from "@anthropic-ai/claude-agent-sdk"

export interface ClaudeAuthClient {
  readonly start: () => Promise<{ readonly url: string }>
  readonly submit: (pasted: string) => Promise<void>
  readonly close: () => void
}

export interface ClaudeAuthSpawn {
  readonly claudePath: string
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
  readonly queryFn?: typeof query
}

interface ClaudeAuthControl {
  claudeAuthenticate(loginWithClaudeAi: boolean): Promise<unknown>
  claudeOAuthCallback(code: string, state: string): Promise<unknown>
  interrupt(): Promise<unknown>
  close(): void
}

export const spawnClaudeAuthClient = (spawn: ClaudeAuthSpawn): ClaudeAuthClient => {
  const q = (spawn.queryFn ?? query)({
    prompt: (async function* () {
      await new Promise(() => {})
      yield undefined as never
    })(),
    options: {
      cwd: spawn.cwd,
      env: spawn.env as Record<string, string>,
      pathToClaudeCodeExecutable: spawn.claudePath
    }
  })
  const control = q as unknown as ClaudeAuthControl
  return {
    start: async () => {
      const response = (await control.claudeAuthenticate(true)) as {
        manualUrl?: string
        automaticUrl?: string
      }
      const url = response.manualUrl ?? response.automaticUrl
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
