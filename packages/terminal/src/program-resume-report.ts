import { createHash, timingSafeEqual } from "node:crypto"

import { decodeBase64Text } from "./base64-text.js"

export const RESUME_PREFIX = "7577;"
export const MAX_RESUME_SEQUENCE = 8192
export const RESUME_TIME_WINDOW_SECONDS = 60
export const MAX_RESUME_BODY =
  MAX_RESUME_SEQUENCE - "\u001b]".length - RESUME_PREFIX.length - "\u001b\\".length

export type ResumeReport =
  | { readonly type: "ignored" }
  | { readonly type: "rejected"; readonly pid: number | undefined; readonly time: number }
  | {
      readonly type: "record"
      readonly pid: number
      readonly time: number
      readonly argv: ReadonlyArray<string>
      readonly cwd: string | undefined
    }
  | { readonly type: "clear"; readonly pid: number; readonly time: number }

export const readResumeReport = (body: string, token: string, nowSeconds: number): ResumeReport => {
  const signed = authenticate(body, token)
  if (signed === undefined) return IGNORED

  const time = positiveInteger(firstValue(signed, "time"))
  if (time === undefined || outsideWindow(time, nowSeconds)) return IGNORED

  const pairs = parsePairs(signed)
  if (pairs === undefined) return rejected(signed, time)
  return interpret(pairs, time) ?? rejected(signed, time)
}

const IGNORED: ResumeReport = { type: "ignored" }
const MAC_MARKER = ":mac="
const MAC = /^[0-9a-f]{64}$/u
const PAIR = /^([a-z]+)=([A-Za-z0-9_.,+/=-]*)$/u
const KEY = /^[a-z]+$/u
const NUMBER = /^[1-9][0-9]*$/u
const IMPLEMENTED_KEYS: ReadonlySet<string> = new Set([
  "pid",
  "time",
  "mac",
  "argv",
  "cwd",
  "clear",
  "need"
])

const authenticate = (body: string, token: string): string | undefined => {
  if (body.length > MAX_RESUME_BODY) return undefined

  const marker = body.lastIndexOf(MAC_MARKER)
  const mac = body.slice(marker + MAC_MARKER.length)
  if (marker === -1 || !MAC.test(mac)) return undefined

  const signed = body.slice(0, marker)
  const expected = createHash("sha256").update(`${signed}:${token}`).digest("hex")
  return timingSafeEqual(Buffer.from(mac), Buffer.from(expected)) ? signed : undefined
}

const outsideWindow = (time: number, nowSeconds: number): boolean =>
  Math.abs(nowSeconds - time) > RESUME_TIME_WINDOW_SECONDS

const firstValue = (signed: string, key: string): string | undefined =>
  signed
    .split(":")
    .find((pair) => pair.startsWith(`${key}=`))
    ?.slice(key.length + 1)

const positiveInteger = (value: string | undefined): number | undefined => {
  if (value === undefined || !NUMBER.test(value)) return undefined
  const parsed = Number(value)
  return Number.isSafeInteger(parsed) ? parsed : undefined
}

const rejected = (signed: string, time: number): ResumeReport => ({
  type: "rejected",
  pid: positiveInteger(firstValue(signed, "pid")),
  time
})

const parsePairs = (signed: string): ReadonlyMap<string, string> | undefined => {
  const pairs = new Map<string, string>()
  for (const pair of signed.split(":")) {
    const match = PAIR.exec(pair)
    if (match === null || pairs.has(match[1]!)) return undefined
    pairs.set(match[1]!, match[2]!)
  }
  return pairs.has("mac") ? undefined : pairs
}

const interpret = (pairs: ReadonlyMap<string, string>, time: number): ResumeReport | undefined => {
  const pid = positiveInteger(pairs.get("pid"))
  if (pid === undefined || !needsImplemented(pairs.get("need"))) return undefined

  const argv = pairs.get("argv")
  const clear = pairs.get("clear")
  if ((argv === undefined) === (clear === undefined)) return undefined
  if (clear !== undefined) return clear === "1" ? { type: "clear", pid, time } : undefined
  return command(pid, time, argv!, pairs.get("cwd"))
}

const needsImplemented = (need: string | undefined): boolean =>
  need === undefined || need.split(",").every((key) => KEY.test(key) && IMPLEMENTED_KEYS.has(key))

const command = (
  pid: number,
  time: number,
  encodedArgv: string,
  encodedCwd: string | undefined
): ResumeReport | undefined => {
  const argv = encodedArgv.split(",").map((element) => decodeBase64Text(element))
  if (!argv.every((element) => element !== undefined) || !validProgram(argv[0]!)) return undefined

  const cwd = encodedCwd === undefined ? undefined : decodeBase64Text(encodedCwd)
  if (encodedCwd !== undefined && !cwd?.startsWith("/")) return undefined
  return { type: "record", pid, time, argv, cwd }
}

const validProgram = (program: string): boolean => {
  if (program.startsWith("/")) return true
  return program !== "" && !program.startsWith("-") && !program.includes("/")
}
