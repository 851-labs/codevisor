import { asRecord } from "../../unknown-values.js"
import type { CloudInboxApi, RouteConfig } from "./plugin-event-ingress.js"

export type CloudRequest = (method: string, path: string, body?: unknown) => Promise<unknown>

export const cloudInboxApi = (request: CloudRequest): CloudInboxApi => ({
  ensure: async (target) => inboxOf(await request("POST", "/api/machine/inboxes", target)),
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

const deviceSubscriptionPath = (inboxId: string): string => `${inboxPath(inboxId)}/devices/self`

const inboxOf = (value: unknown): { readonly id: string; readonly url: string } => {
  const record = asRecord(value)
  if (typeof record.id !== "string" || typeof record.url !== "string") {
    throw new Error("The cloud didn't return an inbox")
  }
  return { id: record.id, url: record.url }
}

const routeConfigOf = (value: unknown): RouteConfig =>
  Object.fromEntries(
    Object.entries(asRecord(asRecord(value).config)).filter(
      (entry): entry is [string, string] => typeof entry[1] === "string"
    )
  )
