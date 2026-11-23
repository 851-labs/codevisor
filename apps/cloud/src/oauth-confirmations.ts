import type { OAuthResult } from "./inbox-frames.js"

export const DEFAULT_OAUTH_RESULT_WAIT_MS = 10_000

export class OAuthConfirmations {
  readonly #waiting = new Map<string, (result: OAuthResult | undefined) => void>()

  constructor(private readonly waitMs: number) {}

  expect(itemId: string): Promise<OAuthResult | undefined> {
    let timer: ReturnType<typeof setTimeout> | undefined
    const answered = new Promise<OAuthResult | undefined>((resolve) => {
      this.#waiting.set(itemId, resolve)
      timer = setTimeout(() => resolve(undefined), this.waitMs)
    })
    return answered.finally(() => {
      clearTimeout(timer)
      this.#waiting.delete(itemId)
    })
  }

  settle(results: readonly OAuthResult[]): void {
    for (const result of results) this.#waiting.get(result.itemId)?.(result)
  }
}
