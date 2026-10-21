export interface McpOAuthClock {
  readonly now: () => number
  readonly setTimeout: (callback: () => void, delayMs: number) => () => void
}
