import type { RequestOptions } from "@modelcontextprotocol/sdk/shared/protocol.js"
import type { ReadResourceResult } from "@modelcontextprotocol/sdk/types.js"
import { z } from "zod"

import {
  accountMeta,
  withMeta,
  type PluginAccountSource,
  type PluginServerName
} from "./mcp-plugin-accounts.js"
import type { NotificationListener, StreamListener } from "./mcp-plugin-channel.js"
import type { UpstreamConnection } from "./mcp-support.js"

export interface PluginRequestOptions {
  readonly signal?: AbortSignal
  readonly timeoutMs?: number
  readonly accountId?: string
}

export interface PluginStreamOptions {
  readonly accountId?: string
  readonly signal: AbortSignal
  readonly onNotification: StreamListener
}

export type PluginExtensions = Readonly<Record<string, Readonly<Record<string, unknown>>>>

export interface PluginConnection {
  readonly serverId: string
  readonly name: string
  readonly extensions: PluginExtensions
  readonly request: (
    method: string,
    params: Record<string, unknown>,
    options?: PluginRequestOptions
  ) => Promise<Record<string, unknown>>
  readonly openStream: (
    method: string,
    params: Record<string, unknown>,
    options: PluginStreamOptions
  ) => Promise<Record<string, unknown>>
  readonly notify: (method: string, params: Record<string, unknown>) => Promise<void>
  readonly onNotification: (method: string, listener: NotificationListener) => () => void
}

export const makePluginConnection = (
  server: PluginServerName,
  connection: UpstreamConnection,
  accounts: PluginAccountSource | undefined
): PluginConnection => {
  const { client, channel } = connection
  const accountParams = async (params: Record<string, unknown>, accountId?: string) =>
    withMeta(params, await accountMeta(accounts, server.id, accountId))

  return {
    serverId: server.id,
    name: server.name,
    extensions: declaredExtensions(connection),
    request: async (method, params, options = {}) => {
      const sent = await accountParams(params, options.accountId)
      return client.request({ method, params: sent }, ResultSchema, requestOptions(options))
    },
    openStream: async (method, params, options) => {
      const sent = await accountParams(params, options.accountId)
      return openStream(connection, { method, params: sent }, options)
    },
    notify: (method, params) => client.notification({ method, params }),
    onNotification: channel.listen
  }
}

export const readPluginResource = async (
  connection: UpstreamConnection,
  accounts: PluginAccountSource | undefined,
  serverId: string,
  uri: string,
  accountId?: string
): Promise<ReadResourceResult> => {
  const meta = await accountMeta(accounts, serverId, accountId)
  return connection.client.readResource({ uri, ...(meta === undefined ? {} : { _meta: meta }) })
}

const longestTimerMs = 2_147_483_647

const ResultSchema = z.looseObject({})

interface StreamRequest {
  readonly method: string
  readonly params: Record<string, unknown>
}

const declaredExtensions = (connection: UpstreamConnection): PluginExtensions => {
  const declared = connection.capabilities.extensions ?? {}
  return Object.fromEntries(Object.entries(declared).map(([id, settings]) => [id, { ...settings }]))
}

const requestOptions = (options: PluginRequestOptions): RequestOptions => ({
  ...(options.signal === undefined ? {} : { signal: options.signal }),
  ...(options.timeoutMs === undefined ? {} : { timeout: options.timeoutMs })
})

const openStream = async (
  connection: UpstreamConnection,
  request: StreamRequest,
  options: PluginStreamOptions
): Promise<Record<string, unknown>> => {
  const { signal } = options
  if (signal.aborted) throw abortError(signal)

  const sent = connection.channel.captureRequestId(() =>
    connection.client.request(request, ResultSchema, { signal, timeout: longestTimerMs })
  )
  const unroute = connection.channel.route(sent.id, options.onNotification)
  try {
    return await sent.value
  } catch (cause) {
    if (signal.aborted) throw abortError(signal)
    throw cause
  } finally {
    unroute()
  }
}

const abortError = (signal: AbortSignal): Error => {
  const reason: unknown = signal.reason
  if (reason instanceof Error && reason.name === "AbortError") return reason
  return new DOMException("The stream was cancelled", "AbortError")
}
