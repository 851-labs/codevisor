import type { McpServerRecord, PluginEventSubscriptionRecord } from "@codevisor/db"

export interface McpServerIdentity {
  readonly id: string
  readonly name: string
}

export type McpServerLifecycleChange =
  | {
      readonly kind: "removed"
      readonly server: McpServerIdentity
      readonly subscriptions: ReadonlyArray<PluginEventSubscriptionRecord>
    }
  | { readonly kind: "turnedOff"; readonly server: McpServerIdentity }
  | { readonly kind: "turnedOn"; readonly server: McpServerIdentity }

export type McpServerLifecycleListener = (change: McpServerLifecycleChange) => void

export interface McpServerLifecycle {
  readonly emit: McpServerLifecycleListener
  readonly subscribe: (listener: McpServerLifecycleListener) => () => void
}

export const makeMcpServerLifecycle = (): McpServerLifecycle => {
  const listeners = new Set<McpServerLifecycleListener>()
  return {
    emit: (change) => {
      for (const listener of Array.from(listeners)) listener(change)
    },
    subscribe: (listener) => {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    }
  }
}

export const enabledChange = (
  before: McpServerRecord,
  after: McpServerRecord
): McpServerLifecycleChange | undefined => {
  if (before.enabled === after.enabled) return undefined
  const server = { id: after.id, name: after.name }
  return after.enabled ? { kind: "turnedOn", server } : { kind: "turnedOff", server }
}
