import { query } from "@anthropic-ai/claude-agent-sdk"

/// The native Claude OAuth flow, driven through the SDK's control channel
/// instead of a rendered PTY: `start` yields the browser URL, `submit`
/// completes the exchange with the code the user pasted back. One client
/// per login attempt; `close` aborts the underlying CLI.
export interface ClaudeAuthClient {
  readonly start: () => Promise<{ readonly url: string }>
  readonly submit: (pasted: string) => Promise<void>
  readonly close: () => void
}

export interface ClaudeAuthSpawn {
  readonly claudePath: string
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
  /// Test seam; defaults to the SDK's query.
  readonly queryFn?: typeof query
}

/// The SDK's OAuth control requests exist at runtime (verified against
/// sdk.mjs 0.3.211 and a live CLI) but are absent from its public Query
/// type; this structural view is the seam we call them through.
interface ClaudeAuthControl {
  claudeAuthenticate(loginWithClaudeAi: boolean): Promise<unknown>
  claudeOAuthCallback(code: string, state: string): Promise<unknown>
  claudeOAuthWaitForCompletion(): Promise<unknown>
  interrupt?(): Promise<void>
  close?(): void
}

export const spawnClaudeAuthClient = (spawn: ClaudeAuthSpawn): ClaudeAuthClient => {
  const q = (spawn.queryFn ?? query)({
    prompt: (async function* () {
      // Auth-only query: no prompt is ever sent. Park until close(); the
      // yield below is unreachable and exists to make that explicit.
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
      // The callback page shows `code#state`; a bare code reuses the state
      // embedded in the URL the CLI generated.
      const [code, state] = pasted.trim().split("#", 2)
      if (!code) throw new Error("Paste the code from Claude's sign-in page")
      await control.claudeOAuthCallback(code, state ?? "")
      await control.claudeOAuthWaitForCompletion()
    },
    close: () => {
      void control.interrupt?.().catch(() => undefined)
      control.close?.()
    }
  }
}
