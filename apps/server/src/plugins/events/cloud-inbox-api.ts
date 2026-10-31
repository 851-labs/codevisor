import { MachineApiError } from "../../infra/cloud-inbox.js"
import { asRecord } from "../../unknown-values.js"
import type { CloudInboxApi, InboxTarget, RouteConfig } from "./plugin-event-ingress.js"

export type CloudRequest = (method: string, path: string, body?: unknown) => Promise<unknown>

export const cloudInboxApi = (request: CloudRequest): CloudInboxApi => ({
  ensure: async (target) => inboxOf(await request("POST", "/api/machine/inboxes", target)),
  find: async (target) => {
    try {
      return inboxIdOf(await request("GET", inboxLookupPath(target)))
    } catch (cause) {
      if (isMissing(cause)) return undefined
      throw cause
    }
  },
  subscribe: async (inboxId) => {
    await request("PUT", deviceSubscriptionPath(inboxId))
  },
  unsubscribe: async (inboxId) => {
    await request("DELETE", deviceSubscriptionPath(inboxId))
  },
  route: async (inboxId, route, key) =>
    routeConfigOf(
      await request("PUT", `${inboxPath(inboxId)}/routes/${encodeURIComponent(route)}`, { key })
    ),
  remove: async (inboxId) => {
    await request("DELETE", inboxPath(inboxId))
  }
})

const inboxPath = (inboxId: string): string => `/api/machine/inboxes/${encodeURIComponent(inboxId)}`

const inboxLookupPath = (target: InboxTarget): string =>
  `/api/machine/inboxes?${new URLSearchParams({ ...target })}`

const deviceSubscriptionPath = (inboxId: string): string => `${inboxPath(inboxId)}/devices/self`

const inboxOf = (value: unknown): { readonly id: string; readonly url: string } => {
  const record = asRecord(value)
  if (typeof record.id !== "string" || typeof record.url !== "string") throw noInbox()
  return { id: record.id, url: record.url }
}

const inboxIdOf = (value: unknown): string => {
  const { id } = asRecord(value)
  if (typeof id !== "string") throw noInbox()
  return id
}

const noInbox = (): Error => new Error("The cloud didn't return an inbox")

const isMissing = (cause: unknown): boolean =>
  cause instanceof MachineApiError && cause.status === 404

const routeConfigOf = (value: unknown): RouteConfig =>
  Object.fromEntries(
    Object.entries(asRecord(asRecord(value).config)).filter(
      (entry): entry is [string, string] => typeof entry[1] === "string"
    )
  )
