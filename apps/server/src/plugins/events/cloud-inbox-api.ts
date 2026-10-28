import { asRecord } from "../../unknown-values.js"
import type { CloudInboxApi } from "./plugin-event-ingress.js"

export type CloudRequest = (method: string, path: string, body?: unknown) => Promise<unknown>

export const cloudInboxApi = (request: CloudRequest): CloudInboxApi => ({
  ensure: async (target) => inboxOf(await request("POST", "/api/machine/inboxes", target)),
  subscribe: async (inboxId) => {
    await request("PUT", deviceSubscriptionPath(inboxId))
  },
  unsubscribe: async (inboxId) => {
    await request("DELETE", deviceSubscriptionPath(inboxId))
  }
})

const deviceSubscriptionPath = (inboxId: string): string =>
  `/api/machine/inboxes/${encodeURIComponent(inboxId)}/devices/self`

const inboxOf = (value: unknown): { readonly id: string; readonly url: string } => {
  const record = asRecord(value)
  if (typeof record.id !== "string" || typeof record.url !== "string") {
    throw new Error("The cloud didn't return an inbox")
  }
  return { id: record.id, url: record.url }
}
