import { z } from "zod"

export type LinearPing = z.infer<typeof linearPing>

export const linearPingOf = (base64Body: string): LinearPing | undefined =>
  linearPing.safeParse(decodedJson(base64Body)).data

const nullableId = z.string().nullable().optional()

const linearPing = z.object({
  organizationId: z.string().min(1),
  type: z.enum(["Issue", "Comment"]),
  action: z.enum(["create", "update"]),
  id: z.string().min(1),
  createdAt: z.string(),
  updatedAt: z.string().optional(),
  actorId: z.string().optional(),
  changed: z.array(z.string()).default([]),
  previous: z
    .object({
      stateId: nullableId,
      assigneeId: nullableId,
      priority: z.number().nullable().optional()
    })
    .default({})
})

const decodedJson = (base64: string): unknown => {
  try {
    return JSON.parse(Buffer.from(base64, "base64").toString("utf8"))
  } catch {
    return undefined
  }
}
