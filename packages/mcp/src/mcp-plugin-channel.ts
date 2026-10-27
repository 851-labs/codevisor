import type { Client } from "@modelcontextprotocol/sdk/client/index.js"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import { isJSONRPCRequest, type RequestId } from "@modelcontextprotocol/sdk/types.js"

import { isNonArrayRecord } from "./mcp-guards.js"

export const SUBSCRIPTION_ID_META_KEY = "io.modelcontextprotocol/subscriptionId"

export type NotificationListener = (params: Record<string, unknown>) => void

export type StreamListener = (method: string, params: Record<string, unknown>) => void

export interface CapturedRequest<T> {
  readonly value: T
  readonly id: RequestId | undefined
}

export interface PluginChannel {
  readonly listen: (method: string, listener: NotificationListener) => () => void
  readonly route: (id: RequestId | undefined, listener: StreamListener) => () => void
  readonly captureRequestId: <T>(send: () => T) => CapturedRequest<T>
}

export const makePluginChannel = (client: Client, transport: Transport): PluginChannel => {
  const listeners = new Map<string, Set<NotificationListener>>()
  const routes = new Map<RequestId, StreamListener>()
  const capture = tapRequestIds(transport)

  client.fallbackNotificationHandler = async ({ method, params }) => {
    const values = params ?? {}
    for (const listener of Array.from(listeners.get(method) ?? [])) listener(values)
    const id = subscriptionId(values)
    if (id !== undefined) routes.get(id)?.(method, values)
  }

  return {
    listen: (method, listener) => {
      const methodListeners = listeners.get(method) ?? new Set()
      methodListeners.add(listener)
      listeners.set(method, methodListeners)
      return () => methodListeners.delete(listener)
    },
    route: (id, listener) => {
      if (id === undefined) return () => undefined
      routes.set(id, listener)
      return () => routes.delete(id)
    },
    captureRequestId: capture
  }
}

const subscriptionId = (params: Record<string, unknown>): RequestId | undefined => {
  const meta = params._meta
  if (!isNonArrayRecord(meta)) return undefined
  const id = meta[SUBSCRIPTION_ID_META_KEY]
  if (typeof id === "string" || typeof id === "number") return id
  return undefined
}

const tapRequestIds = (transport: Transport): PluginChannel["captureRequestId"] => {
  let pending: ((id: RequestId) => void) | undefined
  const send = transport.send.bind(transport)
  transport.send = (message, options) => {
    if (pending !== undefined && isJSONRPCRequest(message)) pending(message.id)
    pending = undefined
    return send(message, options)
  }

  return (start) => {
    let id: RequestId | undefined
    pending = (sent) => {
      id = sent
    }
    try {
      return { value: start(), id }
    } finally {
      pending = undefined
    }
  }
}
