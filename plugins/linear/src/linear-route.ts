import { ingressMeta } from "@codevisor/plugin-kit"
import { z } from "zod"

import { linearIngress } from "./linear-event-catalog.js"

export const hasLinearRoute = (meta: Record<string, unknown> | undefined): boolean =>
  ingressMetaSchema
    .safeParse(meta?.[ingressMeta])
    .data?.ingress.some(
      (ingress) =>
        ingress.name === linearIngress.name && ingress.route?.name === linearIngress.route
    ) ?? false

const ingressMetaSchema = z.object({
  ingress: z.array(
    z.object({
      name: z.string(),
      route: z.object({ name: z.string() }).loose().optional()
    })
  )
})
