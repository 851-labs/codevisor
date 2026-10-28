import type { McpManager } from "@codevisor/mcp"

import type { SessionEventOutbox } from "../../routes/session-event-outbox.js"
import { swallowError, type CodevisorServerServices } from "../../server-context.js"
import { pluginKeyOf } from "../accounts/plugin-accounts.js"
import type { PluginPlatform } from "../plugin-platform.js"
import { cloudInboxApi } from "./cloud-inbox-api.js"
import type { PluginEventConnections } from "./plugin-event-connections.js"
import type { PluginEventIngest } from "./plugin-event-ingest.js"
import { makePluginEventIngress, type PluginEventIngress } from "./plugin-event-ingress.js"
import type { EventTimers } from "./plugin-event-sources.js"
import { makePluginEventWebhooks } from "./plugin-event-webhooks.js"
import { makePluginEvents, type PluginEvents } from "./plugin-events.js"

export const startPluginEvents = (
  services: CodevisorServerServices,
  outbox: SessionEventOutbox
): PluginEvents | undefined => {
  if (services.mcp === undefined) return undefined
  const connections = mcpEventConnections(services.mcp)
  const platform = services.pluginPlatform
  const ingress = platformIngress(platform, connections)
  const webhooks = platformWebhooks(services, platform, connections)
  const events = makePluginEvents({
    db: services.db,
    connections,
    outbox,
    now: Date.now,
    timers: systemEventTimers,
    ...(ingress === undefined ? {} : { ingress }),
    ...(webhooks === undefined ? {} : { webhooks }),
    ...(platform === undefined ? {} : accountHooks(platform))
  })
  void events.start().catch(swallowError)
  return events
}

export const mcpEventConnections = (mcp: McpManager): PluginEventConnections => ({
  servers: () => mcp.list(),
  connection: (serverId) => mcp.pluginConnection(serverId),
  subscribeConnections: (listener) => mcp.subscribeConnections(listener)
})

const platformIngress = (
  platform: PluginPlatform | undefined,
  connections: PluginEventConnections
): PluginEventIngress | undefined => {
  const request = platform?.cloudRequest
  if (platform?.inbox === undefined || request === undefined) return undefined
  const ingress = makePluginEventIngress({
    connections,
    inboxes: cloudInboxApi(request),
    pluginKey: pluginKeyOf
  })
  platform.inbox.onWebhook((webhook) => ingress.deliver(webhook))
  return ingress
}

const platformWebhooks = (
  services: CodevisorServerServices,
  platform: PluginPlatform | undefined,
  connections: PluginEventConnections
) => {
  const request = platform?.cloudRequest
  const inbox = platform?.inbox
  if (platform === undefined || inbox === undefined || request === undefined) return undefined
  return (ingest: PluginEventIngest) => {
    const webhooks = makePluginEventWebhooks({
      db: services.db,
      connections,
      inboxes: cloudInboxApi(request),
      ingest,
      timers: systemEventTimers,
      deviceId: platform.deviceId,
      pluginKey: pluginKeyOf,
      now: Date.now
    })
    inbox.onWebhook((webhook) => webhooks.receive(webhook))
    return webhooks
  }
}

const accountHooks = (platform: PluginPlatform) => ({
  resolveAccount: async (serverId: string, requested?: string) => {
    const choices = await platform.accounts.choices(serverId).catch(() => [])
    if (requested !== undefined) return choiceMatching(choices, requested)
    return choices[0]?.id
  },
  accountLabel: async (serverId: string, accountId: string) =>
    (await platform.accounts.choices(serverId).catch(() => [])).find(
      (choice) => choice.id === accountId
    )?.label
})

const choiceMatching = (
  choices: ReadonlyArray<{ readonly id: string; readonly label: string }>,
  requested: string
): string => {
  const wanted = requested.trim().toLowerCase()
  const match = choices.find(
    (choice) => choice.id === requested || choice.label.toLowerCase() === wanted
  )
  if (match === undefined)
    throw new Error(
      `No account "${requested}". Accounts: ${choices.map((choice) => choice.label).join(", ")}`
    )
  return match.id
}

/* v8 ignore start */
export const systemEventTimers: EventTimers = {
  sleep: (ms, signal) =>
    new Promise((resolve, reject) => {
      if (signal.aborted) return reject(signal.reason)
      const handle = setTimeout(() => {
        signal.removeEventListener("abort", abort)
        resolve()
      }, ms)
      handle.unref?.()
      const abort = () => {
        clearTimeout(handle)
        reject(signal.reason)
      }
      signal.addEventListener("abort", abort, { once: true })
    })
}
/* v8 ignore stop */
