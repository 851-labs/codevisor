import { errorResult } from "@codevisor/plugin-kit"
import {
  type CallToolResult,
  Client,
  SdkHttpError,
  StreamableHTTPClientTransport
} from "@modelcontextprotocol/client"

import { rejectedLinearSignIn } from "./linear-account.js"
import type { Fetch } from "./linear-api.js"

export const linearMcpUrl = "https://mcp.linear.app/mcp"
export const linearMcpTimeoutMs = 60_000

export const callLinearTool = async (
  fetcher: Fetch,
  accessToken: string,
  name: string,
  args: Record<string, unknown>
): Promise<CallToolResult> => {
  const client = new Client({ name: "codevisor-linear", version: "1.0.0" })
  try {
    await client.connect(upstreamTransport(fetcher, accessToken))
    return await client.callTool({ name, arguments: args }, { timeout: linearMcpTimeoutMs })
  } catch (error) {
    return errorResult(failureMessage(error))
  } finally {
    await client.close().catch(() => undefined)
  }
}

const upstreamTransport = (fetcher: Fetch, accessToken: string): StreamableHTTPClientTransport =>
  new StreamableHTTPClientTransport(new URL(linearMcpUrl), {
    fetch: (url, init) => fetcher(String(url), init ?? {}),
    requestInit: { headers: { Authorization: `Bearer ${accessToken}` } }
  })

const failureMessage = (error: unknown): string => {
  if (rejectedToken(error)) return rejectedLinearSignIn

  return `Linear request failed: ${error instanceof Error ? error.message : String(error)}`
}

const rejectedToken = (error: unknown): boolean =>
  SdkHttpError.isInstance(error) && (error.status === unauthorized || error.status === forbidden)

const unauthorized = 401
const forbidden = 403
