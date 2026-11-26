export interface JsonRequest {
  readonly method?: string
  readonly body?: unknown
  readonly timeoutMs?: number
}

export interface JsonAnswer {
  readonly status: number
  readonly body: unknown
}

const defaultTimeoutMs = 5000
const requestTimeout = 408

export const fetchJson = async (
  url: string,
  init: JsonRequest = {}
): Promise<JsonAnswer | undefined> => {
  const timeoutMs = init.timeoutMs ?? defaultTimeoutMs
  try {
    const response = await fetch(url, {
      method: init.method ?? "GET",
      signal: AbortSignal.timeout(timeoutMs),
      ...(init.body === undefined
        ? {}
        : { body: JSON.stringify(init.body), headers: { "content-type": "application/json" } })
    })
    const body: unknown = await response.json().catch(() => undefined)
    return { status: response.status, body }
  } catch (error) {
    return isTimeout(error) ? unanswered(url, timeoutMs) : undefined
  }
}

const isTimeout = (error: unknown): boolean =>
  error instanceof Error && (error.name === "TimeoutError" || error.name === "AbortError")

const unanswered = (url: string, timeoutMs: number): JsonAnswer => ({
  status: requestTimeout,
  body: {
    error: `The Codevisor server on port ${new URL(url).port} is running but didn't answer within ${Math.round(timeoutMs / 1000)} s`
  }
})
