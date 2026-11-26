import { errorResult } from "@codevisor/plugin-kit"
import {
  type CallToolResult,
  Client,
  SdkHttpError,
  StreamableHTTPClientTransport
} from "@modelcontextprotocol/client"

import { rejectedSentrySignIn } from "./sentry-account.js"
import type { Fetch } from "./sentry-api.js"

export const sentryMcpTimeoutMs = 120_000

export const callSentryTool = async (
  fetcher: Fetch,
  mcpUrl: string,
  accessToken: string,
  name: string,
  args: Record<string, unknown>
): Promise<CallToolResult> => {
  const client = new Client({ name: "codevisor-sentry", version: "1.0.0" })
  try {
    await client.connect(upstreamTransport(fetcher, mcpUrl, accessToken))
    return await client.callTool({ name, arguments: args }, { timeout: sentryMcpTimeoutMs })
  } catch (error) {
    return errorResult(failureMessage(error))
  } finally {
    await client.close().catch(() => undefined)
  }
}

const upstreamTransport = (
  fetcher: Fetch,
  mcpUrl: string,
  accessToken: string
): StreamableHTTPClientTransport =>
  new StreamableHTTPClientTransport(new URL(mcpUrl), {
    fetch: (url, init) => fetcher(String(url), init ?? {}),
    requestInit: { headers: { Authorization: `Sentry-Bearer ${accessToken}` } }
  })

const failureMessage = (error: unknown): string => {
  if (rejectedToken(error)) return rejectedSentrySignIn

  return `Sentry request failed: ${error instanceof Error ? error.message : String(error)}`
}

const rejectedToken = (error: unknown): boolean =>
  SdkHttpError.isInstance(error) && (error.status === unauthorized || error.status === forbidden)

const unauthorized = 401
const forbidden = 403
