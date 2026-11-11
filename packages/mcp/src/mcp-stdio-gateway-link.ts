import {
  Client,
  SdkHttpError,
  type StreamableHTTPClientTransport
} from "@modelcontextprotocol/client"

import { streamableHttpTransport } from "./mcp-http-transport.js"

export interface IssuedGateway {
  readonly url: string
  readonly bearerToken: string
}

export interface GatewayLink {
  readonly use: <T>(operation: (client: Client) => Promise<T>) => Promise<T>
  readonly close: () => Promise<void>
}

export interface GatewayLinkOptions {
  readonly version: string
  readonly issue: () => Promise<IssuedGateway>
  readonly onToolsChanged: () => void
}

interface LinkedGateway {
  readonly client: Client
  readonly transport: StreamableHTTPClientTransport
}

const notFoundStatus = 404

export const makeGatewayLink = (options: GatewayLinkOptions): GatewayLink => {
  let linked: Promise<LinkedGateway> | undefined
  let closing: Promise<void> | undefined

  const current = (): Promise<LinkedGateway> => {
    if (linked !== undefined) return linked
    const attempt = connectGateway(options)
    linked = attempt
    attempt.catch(() => forget(attempt))
    return attempt
  }

  const forget = (stale: Promise<LinkedGateway>): void => {
    if (linked === stale) linked = undefined
  }

  const use = async <T>(operation: (client: Client) => Promise<T>): Promise<T> => {
    const attempt = current()
    const { client } = await attempt
    try {
      return await operation(client)
    } catch (cause) {
      if (!gatewayIsGone(cause)) throw cause
      forget(attempt)
      void closeLinked(attempt)
      return operation((await current()).client)
    }
  }

  const close = (): Promise<void> => {
    closing ??= closeCurrent()
    return closing
  }

  const closeCurrent = async (): Promise<void> => {
    const open = linked
    linked = undefined
    if (open !== undefined) await closeLinked(open, { terminate: true })
  }

  return { use, close }
}

const connectGateway = async (options: GatewayLinkOptions): Promise<LinkedGateway> => {
  const gateway = await options.issue()
  const transport = streamableHttpTransport(new URL(gateway.url), gateway.bearerToken)
  const client = new Client({ name: "codevisor mcp", version: options.version })
  client.setNotificationHandler("notifications/tools/list_changed", options.onToolsChanged)
  await client.connect(transport)
  return { client, transport }
}

const closeLinked = async (
  attempt: Promise<LinkedGateway>,
  { terminate = false }: { readonly terminate?: boolean } = {}
): Promise<void> => {
  const open = await attempt.catch(() => undefined)
  if (open === undefined) return
  if (terminate) await open.transport.terminateSession().catch(() => undefined)
  await open.client.close().catch(() => undefined)
}

const gatewayIsGone = (cause: unknown): boolean =>
  (cause instanceof SdkHttpError && cause.status === notFoundStatus) || connectionRefused(cause)

const connectionRefused = (cause: unknown): boolean => {
  let current: unknown = cause
  while (current instanceof Error) {
    if ("code" in current && current.code === "ECONNREFUSED") return true
    current = current.cause
  }
  return false
}
