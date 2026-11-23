export interface PostHogEvent {
  readonly event: string
  readonly distinct_id: string
  readonly timestamp: string
  readonly properties: Readonly<Record<string, unknown>>
}

export type SendPostHogEvent = (event: PostHogEvent) => Promise<void>

export const postHogSender =
  (
    options: { readonly projectToken: string; readonly host: string },
    request: typeof fetch = fetch
  ) =>
  async (event: PostHogEvent): Promise<void> => {
    await request(new URL("/i/v0/e/", options.host), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ api_key: options.projectToken, ...event }),
      signal: AbortSignal.timeout(sendTimeoutMs)
    })
  }

const sendTimeoutMs = 10_000
