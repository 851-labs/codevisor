import { z } from "zod"

import { accountMeta } from "./plugin-protocol.js"

export interface PluginAccount {
  id: string
  label?: string | undefined
  identity?: string | undefined
  accessToken?: string | undefined
  fields: Record<string, unknown>
}

export const accountFromMeta = (
  meta: Record<string, unknown> | undefined
): PluginAccount | undefined => {
  const parsed = accountSchema.safeParse(meta?.[accountMeta])
  if (!parsed.success) return undefined

  return parsed.data
}

const accountSchema = z.object({
  id: z.string().min(1),
  label: z.string().optional(),
  identity: z.string().optional(),
  accessToken: z.string().optional(),
  fields: z.record(z.string(), z.unknown()).default({})
})
