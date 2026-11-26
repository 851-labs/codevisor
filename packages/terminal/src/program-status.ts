import type { TerminalActivity } from "@codevisor/api"

import { decodeBase64Text } from "./base64-text.js"
import { makeOscScanner, type OscEvent } from "./osc-scanner.js"

type ReportState = TerminalActivity | "clear"

const STATES: ReadonlySet<string> = new Set<ReportState>([
  "idle",
  "working",
  "done",
  "blocked",
  "error",
  "clear"
])

const isReportState = (value: string): value is ReportState => STATES.has(value)

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

const validId = (id: string): boolean => {
  const segments = id.split("/")
  return (
    id.length <= MAX_ID &&
    segments.length <= MAX_ID_DEPTH &&
    segments.every((segment) => ID_SEGMENT.test(segment))
  )
}

const validText = (encoded: string, maxBytes: number): boolean =>
  decodeBase64Text(encoded, maxBytes) !== undefined

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
  if (state === undefined || !isReportState(state)) return undefined
  return { type: "report", state, id: last("id") }
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

export const makeProgramStatusScanner = (): ProgramStatusScanner => {
  const osc = makeOscScanner([
    { prefix: PREFIX, maxLength: PREFIX.length + MAX_BODY },
    { prefix: PROMPT, maxLength: MAX_PROMPT }
  ])
  return { scan: (data) => osc.scan(data).flatMap(programStatusEvents) }
}

const programStatusEvents = (event: OscEvent): ReadonlyArray<ProgramStatusEvent> => {
  if (event.type === "reset") return [event]
  if (event.body.startsWith(PROMPT)) return [{ type: "prompt" }]
  const report = parseProgramStatus(event.body.slice(PREFIX.length))
  if (report === undefined) return []
  if (report.type === "query") return [{ ...report, terminator: event.terminator }]
  return [report]
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
            records.delete(records.keys().next().value!)
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
