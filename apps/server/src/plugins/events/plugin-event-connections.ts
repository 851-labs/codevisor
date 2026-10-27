import type { McpServer } from "@codevisor/api"

export interface EventConnection {
  readonly serverId: string
  readonly name: string
  readonly request: (
    method: string,
    params: Record<string, unknown>,
    options?: {
      readonly signal?: AbortSignal
      readonly timeoutMs?: number
      readonly accountId?: string
    }
  ) => Promise<Record<string, unknown>>
  readonly openStream: (
    method: string,
    params: Record<string, unknown>,
    options: {
      readonly accountId?: string
      readonly signal: AbortSignal
      readonly onNotification: (method: string, params: Record<string, unknown>) => void
    }
  ) => Promise<Record<string, unknown>>
  readonly notify: (method: string, params: Record<string, unknown>) => Promise<void>
  readonly onNotification: (
    method: string,
    listener: (params: Record<string, unknown>) => void
  ) => () => void
}

export interface PluginEventConnections {
  readonly servers: () => Promise<ReadonlyArray<McpServer>>
  readonly connection: (serverId: string) => Promise<EventConnection>
  readonly subscribeConnections: (
    listener: (serverId: string, state: "connected" | "closed") => void
  ) => () => void
}

export const EVENTS_EXTENSION = "io.modelcontextprotocol/events"

export const offersEvents = (server: McpServer): boolean =>
  server.enabled && (server.capabilities?.events.length ?? 0) > 0
