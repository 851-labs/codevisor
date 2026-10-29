import { z } from "zod"

export interface GmailPart {
  partId?: string | undefined
  mimeType?: string | undefined
  filename?: string | undefined
  headers?: Array<{ name: string; value: string }> | undefined
  body?: { data?: string | undefined; size?: number | undefined } | undefined
  parts?: Array<GmailPart> | undefined
}

export const gmailPart: z.ZodType<GmailPart> = z.lazy(() =>
  z.object({
    partId: z.string().optional(),
    mimeType: z.string().optional(),
    filename: z.string().optional(),
    headers: z.array(z.object({ name: z.string(), value: z.string() })).optional(),
    body: z.object({ data: z.string().optional(), size: z.number().optional() }).optional(),
    parts: z.array(gmailPart).optional()
  })
)

export const gmailMessage = z.object({
  id: z.string(),
  threadId: z.string(),
  labelIds: z.array(z.string()).default([]),
  snippet: z.string().default(""),
  internalDate: z.string().default("0"),
  payload: gmailPart.default({})
})

export const gmailMessageList = z.object({
  messages: z.array(z.object({ id: z.string() })).default([]),
  nextPageToken: z.string().optional()
})

export const gmailThread = z.object({
  id: z.string(),
  messages: z.array(gmailMessage).default([])
})

export const gmailThreadList = z.object({
  threads: z.array(z.object({ id: z.string() })).default([]),
  nextPageToken: z.string().optional()
})

export const gmailProfile = z.object({ emailAddress: z.string(), historyId: z.string() })

export const gmailHistoryPage = z.object({
  history: z
    .array(
      z.object({
        id: z.string(),
        messagesAdded: z.array(z.object({ message: z.object({ id: z.string() }) })).default([])
      })
    )
    .default([]),
  historyId: z.string(),
  nextPageToken: z.string().optional()
})

export const gmailLabel = z.object({
  id: z.string(),
  name: z.string(),
  type: z.string().default("user")
})

export const gmailLabelList = z.object({ labels: z.array(gmailLabel).default([]) })

export const gmailDraft = z.object({
  id: z.string(),
  message: gmailMessage
})

export const gmailWatch = z.object({ historyId: z.string(), expiration: z.string() })

export const noContent = z.object({})

export type GmailMessage = z.infer<typeof gmailMessage>
export type GmailMessageList = z.infer<typeof gmailMessageList>
export type GmailThread = z.infer<typeof gmailThread>
export type GmailThreadList = z.infer<typeof gmailThreadList>
export type GmailProfile = z.infer<typeof gmailProfile>
export type GmailHistoryPage = z.infer<typeof gmailHistoryPage>
export type GmailLabel = z.infer<typeof gmailLabel>
export type GmailDraft = z.infer<typeof gmailDraft>
export type GmailWatch = z.infer<typeof gmailWatch>
