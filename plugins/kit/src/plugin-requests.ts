import { z } from "zod"

const subscriptionArguments = z.record(z.string(), z.unknown()).optional()
const resumeCursor = z.string().nullish()
const maxAgeMs = z.number().int().nonnegative().optional()

export const eventsListRequest = {
  method: "events/list",
  params: z.object({ cursor: z.string().optional() })
}

export const eventsPollRequest = {
  method: "events/poll",
  params: z.object({
    name: z.string(),
    arguments: subscriptionArguments,
    cursor: resumeCursor,
    maxAgeMs,
    maxEvents: z.number().int().positive().optional()
  })
}

export const eventsStreamRequest = {
  method: "events/stream",
  params: z.object({
    name: z.string(),
    arguments: subscriptionArguments,
    cursor: resumeCursor,
    maxAgeMs
  })
}

export const webhookRequest = {
  method: "codevisor/webhook",
  params: z.object({
    ingress: z.string(),
    request: z.object({
      method: z.string(),
      headers: z.record(z.string(), z.string()),
      body: z.string(),
      receivedAt: z.string()
    })
  })
}

export const accountRemoveRequest = {
  method: "codevisor/account/remove",
  params: z.object({}).loose()
}

export const accountCheckRequest = {
  method: "codevisor/account/check",
  params: z.object({}).loose()
}

export const skillsListRequest = {
  method: "skills/list",
  params: z.object({ cursor: z.string().optional() })
}

export const skillsGetRequest = {
  method: "skills/get",
  params: z.object({ uri: z.string() })
}

export type EventsPollParams = z.infer<typeof eventsPollRequest.params>
export type EventsStreamParams = z.infer<typeof eventsStreamRequest.params>
export type WebhookParams = z.infer<typeof webhookRequest.params>
