import { z } from "zod"

const subscriptionArguments = z.record(z.string(), z.unknown()).optional()
const resumeCursor = z.string().nullish()
const maxAgeMs = z.number().int().nonnegative().optional()

export const eventsListRequest = z.object({
  method: z.literal("events/list"),
  params: z.object({ cursor: z.string().optional() }).optional()
})

export const eventsPollRequest = z.object({
  method: z.literal("events/poll"),
  params: z.object({
    name: z.string(),
    arguments: subscriptionArguments,
    cursor: resumeCursor,
    maxAgeMs,
    maxEvents: z.number().int().positive().optional()
  })
})

export const eventsStreamRequest = z.object({
  method: z.literal("events/stream"),
  params: z.object({
    name: z.string(),
    arguments: subscriptionArguments,
    cursor: resumeCursor,
    maxAgeMs
  })
})

export const webhookRequest = z.object({
  method: z.literal("codevisor/webhook"),
  params: z.object({
    ingress: z.string(),
    request: z.object({
      method: z.string(),
      headers: z.record(z.string(), z.string()),
      body: z.string(),
      receivedAt: z.string()
    })
  })
})

export const accountRemoveRequest = z.object({
  method: z.literal("codevisor/account/remove"),
  params: z.object({}).loose().optional()
})

export const accountSignInRequest = z.object({
  method: z.literal("codevisor/account/signIn"),
  params: z.object({
    values: z.record(z.string(), z.union([z.string(), z.number(), z.boolean()])).default({}),
    scopes: z.array(z.string()).default([])
  })
})

export const skillsListRequest = z.object({
  method: z.literal("skills/list"),
  params: z.object({ cursor: z.string().optional() }).optional()
})

export const skillsGetRequest = z.object({
  method: z.literal("skills/get"),
  params: z.object({ uri: z.string() })
})

export type EventsPollParams = z.infer<typeof eventsPollRequest>["params"]
export type EventsStreamParams = z.infer<typeof eventsStreamRequest>["params"]
export type WebhookParams = z.infer<typeof webhookRequest>["params"]
export type AccountSignInParams = z.infer<typeof accountSignInRequest>["params"]
