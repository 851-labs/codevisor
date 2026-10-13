import type { TerminalActivity } from "@codevisor/api"

/// The Program Status Protocol (OSC 7501), revision 0.4: a program tells its
/// terminal what it is doing, so status needs no guessing from titles.
/// https://www.superlogical.com/rex/docs/build/program-status
///
/// ```
/// ESC ] 7501 ; state=blocked:kind=permission:app=terraform:msg=<base64> ESC \
/// ```
///
/// Only `state` and `id` decide what a pane shows, so records keep just
/// those; every other key is still validated, because a report that breaks
/// any rule is discarded whole.

type ReportState = TerminalActivity | "clear"

const STATES: ReadonlySet<string> = new Set<ReportState>([
  "idle",
  "working",
  "done",
  "blocked",
  "error",
  "clear"
])

/// The reply to a support query (`OSC 7501 ; ? ST`): `clear` is a command,
/// not a state, so the list leaves it out.
export const PROGRAM_STATUS_QUERY_REPLY =
  "?:states=idle,working,done,blocked,error:kinds=permission,question,auth"

// Limits from the specification, all in bytes. Every key and value is
// ASCII, so string lengths are byte counts.
const PREFIX = "7501;"
const MAX_SEQUENCE = 4096
/// Everything after `7501;`, assuming the two-byte `ESC \` terminator.
const MAX_BODY = MAX_SEQUENCE - "\u001b]".length - PREFIX.length - "\u001b\\".length
const MAX_KEY = 16
const MAX_APP = 32
const MAX_TITLE_ENCODED = 256
const MAX_TITLE = 192
const MAX_MSG_ENCODED = 2732
const MAX_MSG = 2048
const MAX_ID = 128
const MAX_ID_DEPTH = 8
/// Past this many records the least recently updated one is evicted.
export const MAX_PROGRAM_STATUS_RECORDS = 256

const KEY = /^[a-z]+$/u
const VALUE = /^[A-Za-z0-9_.,+/=-]*$/u
const ID_SEGMENT = /^[A-Za-z0-9_.+-]{1,32}$/u
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/u
// oxlint-disable-next-line no-control-regex -- the C0 and C1 controls the spec forbids in text
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

/// Whether `encoded` is standard base64 (padding optional) of UTF-8 text with
/// no control characters, at most `maxBytes` long once decoded.
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

/// Reads one OSC 7501 body (everything after `7501;`). Undefined when the
/// specification says to ignore the report: no known `state`, an invalid
/// `id`, a broken limit, or `title`/`msg` that isn't safe base64 text. A
/// malformed pair or an unknown key is skipped on its own.
export const parseProgramStatus = (body: string): ProgramStatusReport | undefined => {
  if (body.length > MAX_BODY) return undefined
  if (body === "?") return { type: "query" }
  const values = new Map<string, Array<string>>()
  for (const pair of body.split(":")) {
    const equals = pair.indexOf("=")
    if (equals === -1) continue
    const key = pair.slice(0, equals).trim()
    // An overlong key breaks a limit even when it's a key nobody knows.
    if (key.length > MAX_KEY) return undefined
    const value = pair.slice(equals + 1).trim()
    if (!KEY.test(key) || !VALUE.test(value)) continue
    values.set(key, [...(values.get(key) ?? []), value])
  }
  const all = (key: string): ReadonlyArray<string> => values.get(key) ?? []
  const last = (key: string): string | undefined => all(key).at(-1)

  // Every value counts against its limit, even one a later pair replaces.
  // An invalid id discards the report rather than falling back to the root
  // record, where `clear` would remove everything.
  if (!all("id").every(validId)) return undefined
  if (all("app").some((app) => app.length > MAX_APP)) return undefined
  if (all("title").some((title) => title.length > MAX_TITLE_ENCODED)) return undefined
  if (all("msg").some((msg) => msg.length > MAX_MSG_ENCODED)) return undefined
  const title = last("title")
  if (title !== undefined && !validText(title, MAX_TITLE)) return undefined
  const msg = last("msg")
  if (msg !== undefined && !validText(msg, MAX_MSG)) return undefined

  const state = last("state")
  if (state === undefined || !STATES.has(state)) return undefined
  return { type: "report", state: state as ReportState, id: last("id") }
}

export type ProgramStatusEvent =
  | Exclude<ProgramStatusReport, { type: "query" }>
  /// A support query, answered with the terminator it arrived with.
  | { readonly type: "query"; readonly terminator: string }
  /// A shell prompt starts (OSC 133 `A`).
  | { readonly type: "prompt" }
  /// A full reset (RIS, `ESC c`).
  | { readonly type: "reset" }

export interface ProgramStatusScanner {
  /// Scans a chunk of output and returns what it held, in order. A sequence
  /// split across chunks is completed by the next one.
  readonly scan: (data: string) => ReadonlyArray<ProgramStatusEvent>
}

const PROMPT = "133;A"
/// Prompt marks carry a few short options (`133;A;cl=m;aid=…`).
const MAX_PROMPT = 256

/// Whether an unterminated OSC body could still become one this scanner
/// reads, so it is worth carrying into the next chunk.
const pendingBody = (body: string): boolean => {
  if (body.startsWith(PREFIX)) return body.length - PREFIX.length <= MAX_BODY
  if (body.startsWith(PROMPT)) return body.length <= MAX_PROMPT
  return PREFIX.startsWith(body) || PROMPT.startsWith(body)
}

export const makeProgramStatusScanner = (): ProgramStatusScanner => {
  // The start of a sequence the previous chunk ended inside of.
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
        // An OSC ends at BEL or ST (`ESC \`); any other escape aborts it.
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

/// Most urgent first: what a pane shows when a terminal holds several
/// records. The same order chats use (error, waiting on the user, working,
/// unread).
const URGENCY: ReadonlyArray<TerminalActivity> = ["error", "blocked", "working", "done", "idle"]

export interface ProgramStatusRecords {
  readonly apply: (event: Exclude<ProgramStatusEvent, { type: "query" }>) => void
  /// The most urgent record's state; undefined while the terminal holds no
  /// records, so a program that never reports leaves status to its title.
  readonly summary: () => TerminalActivity | undefined
}

/// One terminal's records, keyed by id (the root record under ""). Each report
/// replaces its record; nothing expires on a timer.
export const makeProgramStatusRecords = (): ProgramStatusRecords => {
  // Insertion order is update order, so the first key is the least recently
  // updated.
  const records = new Map<string, TerminalActivity>()
  return {
    apply: (event) => {
      switch (event.type) {
        case "reset":
          records.clear()
          return
        case "prompt":
          // The program that reported is gone. `working` and `blocked` must
          // go; `idle` may, and dropping it hands status back to titles.
          // `done` and `error` stay until the program replaces or clears them.
          for (const [id, state] of records) {
            if (state !== "done" && state !== "error") records.delete(id)
          }
          return
        case "report": {
          if (event.state === "clear") {
            // Without an id: every record. With one: it and those beneath it.
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
