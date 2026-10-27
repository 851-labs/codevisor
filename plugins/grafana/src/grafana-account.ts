import { accountFromMeta } from "@codevisor/plugin-kit"
import { z } from "zod"

export interface GrafanaAccount {
  id: string
  url: string
  token: string
  webhookSecret: string | undefined
}

export const grafanaAccount = (
  meta: Record<string, unknown> | undefined
): GrafanaAccount | undefined => {
  const account = accountFromMeta(meta)
  const fields = grafanaFields.safeParse(account?.fields)
  if (account === undefined || !fields.success) return undefined

  return {
    id: account.id,
    url: fields.data.url.replace(trailingSlashes, ""),
    token: fields.data.token,
    webhookSecret: fields.data.webhookSecret
  }
}

const grafanaFields = z.object({
  url: z.url(),
  token: z.string().min(1),
  webhookSecret: z.string().min(1).optional()
})

const trailingSlashes = /\/+$/
