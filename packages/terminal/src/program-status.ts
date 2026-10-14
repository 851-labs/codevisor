import type { TerminalActivity } from "@codevisor/api"

type ReportState = TerminalActivity | "clear"

const STATES: ReadonlySet<string> = new Set<ReportState>([
  "idle",
  "working",
  "done",
  "blocked",
  "error",
  "clear"
])

export const PROGRAM_STATUS_QUERY_REPLY =
  "?:states=idle,working,done,blocked,error:kinds=permission,question,auth"

const PREFIX = "7501;"
const MAX_SEQUENCE = 4096
const MAX_BODY = MAX_SEQUENCE - "\u001b]".length - PREFIX.length - "\u001b\\".length
const MAX_KEY = 16
const MAX_APP = 32
const MAX_TITLE_ENCODED = 256
const MAX_TITLE = 192
const MAX_MSG_ENCODED = 2732
const MAX_MSG = 2048
const MAX_ID = 128
const MAX_ID_DEPTH = 8
export const MAX_PROGRAM_STATUS_RECORDS = 256

const KEY = /^[a-z]+$/u
const VALUE = /^[A-Za-z0-9_.,+/=-]*$/u
const ID_SEGMENT = /^[A-Za-z0-9_.+-]{1,32}$/u
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/u
// oxlint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u001f\u007f-\u009f]/u
const utf8 = new TextDecoder("utf-8", { fatal: true })

const validId = (id: string): boolean => {
  const segments = id.split("/")
  return (
    id.length <= MAX_ID &&
    segments.length <= MAX_ID_DEPTH &&
    segments.every((segment) => ID_SEGMENT.test(segment))
  )
}

const validText = (encoded: string, maxBytes: number): boolean => {
  if (!BASE64.test(encoded)) return false
  const padded = encoded.endsWith("=")
  if (padded ? encoded.length % 4 !== 0 : encoded.length % 4 === 1) return false
  const bytes = Buffer.from(encoded, "base64")
  if (bytes.length > maxBytes) return false
  try {
    return !CONTROL.test(utf8.decode(bytes))
  } catch {
    return false
  }
}

export type ProgramStatusReport =
  | { readonly type: "query" }
  | { readonly type: "report"; readonly state: ReportState; readonly id: string | undefined }

const collectProgramStatusValues = (body: string): Map<string, Array<string>> | undefined => {
  const values = new Map<string, Array<string>>()
  for (const pair of body.split(":")) {
    const equals = pair.indexOf("=")
    if (equals === -1) continue
    const key = pair.slice(0, equals).trim()
    if (key.length > MAX_KEY) return undefined
    const value = pair.slice(equals + 1).trim()
    if (!KEY.test(key) || !VALUE.test(value)) continue
    values.set(key, [...(values.get(key) ?? []), value])
  }
  return values
}

const validProgramStatusValues = (
  all: (key: string) => ReadonlyArray<string>,
  last: (key: string) => string | undefined
): boolean => {
  if (!all("id").every(validId)) return false
  if (all("app").some((app) => app.length > MAX_APP)) return false
  if (all("title").some((title) => title.length > MAX_TITLE_ENCODED)) return false
  if (all("msg").some((msg) => msg.length > MAX_MSG_ENCODED)) return false
  const title = last("title")
  if (title !== undefined && !validText(title, MAX_TITLE)) return false
  const msg = last("msg")
  if (msg !== undefined && !validText(msg, MAX_MSG)) return false

  return true
}

export const parseProgramStatus = (body: string): ProgramStatusReport | undefined => {
  if (body.length > MAX_BODY) return undefined
  if (body === "?") return { type: "query" }
  const values = collectProgramStatusValues(body)
  if (values === undefined) return undefined
  const all = (key: string): ReadonlyArray<string> => values.get(key) ?? []
  const last = (key: string): string | undefined => all(key).at(-1)

  if (!validProgramStatusValues(all, last)) return undefined

  const state = last("state")
  if (state === undefined || !STATES.has(state)) return undefined
  return { type: "report", state: state as ReportState, id: last("id") }
}

export type ProgramStatusEvent =
  | Exclude<ProgramStatusReport, { type: "query" }>
  | { readonly type: "query"; readonly terminator: string }
  | { readonly type: "prompt" }
  | { readonly type: "reset" }

export interface ProgramStatusScanner {
  readonly scan: (data: string) => ReadonlyArray<ProgramStatusEvent>
}

const PROMPT = "133;A"
const MAX_PROMPT = 256

const pendingBody = (body: string): boolean => {
  if (body.startsWith(PREFIX)) return body.length - PREFIX.length <= MAX_BODY
  if (body.startsWith(PROMPT)) return body.length <= MAX_PROMPT
  return PREFIX.startsWith(body) || PROMPT.startsWith(body)
}

export const makeProgramStatusScanner = (): ProgramStatusScanner => {
  let carry = ""
  return {
    scan: (data) => {
      const text = carry + data
      carry = ""
      const events: Array<ProgramStatusEvent> = []
      let index = text.indexOf("\u001b")
      while (index !== -1) {
        const next = text[index + 1]
        if (next === undefined) {
          carry = text.slice(index)
          break
        }
        if (next === "c") events.push({ type: "reset" })
        if (next !== "]") {
          index = text.indexOf("\u001b", index + 1)
          continue
        }
        const start = index + 2
        const bel = text.indexOf("\u0007", start)
        const esc = text.indexOf("\u001b", start)
        const end = bel !== -1 && (esc === -1 || bel < esc) ? bel : esc
        if (end === -1 || (end === esc && text[esc + 1] === undefined)) {
          if (pendingBody(text.slice(start))) carry = text.slice(index)
          break
        }
        const terminated = end === bel || text[esc + 1] === "\\"
        const body = text.slice(start, end)
        if (terminated && body.startsWith(PREFIX)) {
          const report = parseProgramStatus(body.slice(PREFIX.length))
          if (report?.type === "query")
            events.push({ ...report, terminator: text.slice(end, end + (end === bel ? 1 : 2)) })
          else if (report !== undefined) events.push(report)
        } else if (terminated && body.startsWith(PROMPT)) {
          events.push({ type: "prompt" })
        }
        index = terminated ? text.indexOf("\u001b", end + 1) : end
      }
      return events
    }
  }
}

const URGENCY: ReadonlyArray<TerminalActivity> = ["error", "blocked", "working", "done", "idle"]

export interface ProgramStatusRecords {
  readonly apply: (event: Exclude<ProgramStatusEvent, { type: "query" }>) => void
  readonly summary: () => TerminalActivity | undefined
}

export const makeProgramStatusRecords = (): ProgramStatusRecords => {
  const records = new Map<string, TerminalActivity>()
  return {
    apply: (event) => {
      switch (event.type) {
        case "reset":
          records.clear()
          return
        case "prompt":
          for (const [id, state] of records) {
            if (state !== "done" && state !== "error") records.delete(id)
          }
          return
        case "report": {
          if (event.state === "clear") {
            const cleared = event.id
            for (const id of records.keys()) {
              if (cleared === undefined || id === cleared || id.startsWith(`${cleared}/`)) {
                records.delete(id)
              }
            }
            return
          }
          const id = event.id ?? ""
          records.delete(id)
          records.set(id, event.state)
          if (records.size > MAX_PROGRAM_STATUS_RECORDS) {
            records.delete(records.keys().next().value as string)
          }
        }
      }
    },
    summary: () => {
      const states = new Set(records.values())
      return URGENCY.find((state) => states.has(state))
    }
  }
}
