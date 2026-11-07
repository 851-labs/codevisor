import { z } from "zod"

export interface FakeLabel {
  id: string
  name: string
  type: string
  color?: { backgroundColor: string; textColor: string } | undefined
  labelListVisibility?: string | undefined
  messageListVisibility?: string | undefined
}

export interface FakeLabelRequest {
  method: string
  body: Record<string, unknown> | undefined
}

export const fakeLabels: ReadonlyArray<FakeLabel> = [
  { id: "INBOX", name: "INBOX", type: "system" },
  { id: "UNREAD", name: "UNREAD", type: "system" },
  { id: "STARRED", name: "STARRED", type: "system" },
  { id: "Label_1", name: "Receipts", type: "user" }
]

export const labelResponse = (
  labels: Array<FakeLabel>,
  request: FakeLabelRequest,
  id: string | undefined
): Response => {
  if (id === undefined && request.method === "POST") return created(labels, request.body)
  if (id === undefined) return json(200, { labels })

  const label = labels.find((candidate) => candidate.id === id)
  if (label === undefined) return json(404, { error: { code: 404, message: "Not Found" } })
  if (request.method === "DELETE") return deleted(labels, label)

  return patched(labels, label, request.body)
}

const created = (labels: Array<FakeLabel>, body: Record<string, unknown> | undefined) => {
  const { name = "", ...settings } = labelFields.parse(body)
  if (nameTaken(labels, name)) return conflict()

  const label = Object.assign({ id: `Label_${labels.length + 1}`, name, type: "user" }, settings)
  labels.push(label)
  return json(200, label)
}

const patched = (
  labels: Array<FakeLabel>,
  label: FakeLabel,
  body: Record<string, unknown> | undefined
): Response => {
  const fields = labelFields.parse(body)
  const others = labels.filter((candidate) => candidate !== label)
  if (fields.name !== undefined && nameTaken(others, fields.name)) return conflict()

  return json(200, Object.assign(label, fields))
}

const deleted = (labels: Array<FakeLabel>, label: FakeLabel): Response => {
  labels.splice(labels.indexOf(label), 1)
  return new Response(null, { status: 204 })
}

const nameTaken = (labels: ReadonlyArray<FakeLabel>, name: string): boolean =>
  labels.some((label) => label.name.toLowerCase() === name.toLowerCase())

const conflict = (): Response =>
  json(409, { error: { code: 409, message: "Label name exists or conflicts" } })

const labelFields = z.object({
  name: z.string().optional(),
  color: z.object({ backgroundColor: z.string(), textColor: z.string() }).optional(),
  labelListVisibility: z.string().optional(),
  messageListVisibility: z.string().optional()
})

const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
