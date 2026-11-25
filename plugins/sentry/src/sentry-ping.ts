import { z } from "zod"

export type SentryPing = z.infer<typeof sentryPing>

export const sentryPingOf = (base64Body: string): SentryPing | undefined =>
  sentryPing.safeParse(decodedJson(base64Body)).data

const sentryPing = z.object({
  organizationId: z.string().min(1),
  resource: z.enum(["issue", "comment", "event_alert", "metric_alert"]),
  action: z.string(),
  issueId: z.string().optional(),
  substatus: z.string().optional(),
  commentId: z.string().optional(),
  eventId: z.string().optional(),
  alert: z
    .object({ rule: z.string(), status: z.string(), incidentId: z.string().optional() })
    .optional(),
  timestamp: z.string()
})

const decodedJson = (base64: string): unknown => {
  try {
    return JSON.parse(Buffer.from(base64, "base64").toString("utf8"))
  } catch {
    return undefined
  }
}
