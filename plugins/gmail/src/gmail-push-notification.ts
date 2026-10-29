import { ingressMeta } from "@codevisor/plugin-kit"
import { z } from "zod"

import { gmailIngress } from "./gmail-event-catalog.js"

export interface GmailNotification {
  emailAddress: string
  historyId: string
}

export const gmailNotificationOf = (base64Body: string): GmailNotification | undefined => {
  const parsed = gmailNotification.safeParse(decodedJson(base64Body))
  if (!parsed.success) return undefined

  return { emailAddress: parsed.data.emailAddress, historyId: String(parsed.data.historyId) }
}

export const pushTopicOf = (meta: Record<string, unknown> | undefined): string | undefined =>
  ingressMetaSchema
    .safeParse(meta?.[ingressMeta])
    .data?.ingress.find((ingress) => ingress.name === gmailIngress.name)?.route?.topic

const gmailNotification = z.object({
  emailAddress: z.string().min(1),
  historyId: z.union([z.string().regex(/^\d+$/), z.number().int().nonnegative()])
})

const ingressMetaSchema = z.object({
  ingress: z.array(
    z.object({
      name: z.string(),
      route: z
        .object({ topic: z.string().min(1) })
        .loose()
        .optional()
    })
  )
})

const decodedJson = (base64: string): unknown => {
  try {
    return JSON.parse(Buffer.from(base64, "base64").toString("utf8"))
  } catch {
    return undefined
  }
}
