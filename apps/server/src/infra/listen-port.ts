import { existsSync, readFileSync } from "node:fs"
import { join } from "node:path"

import { writeJsonStateFile } from "../json-state-file.js"
import { field } from "../unknown-values.js"

export const DEFAULT_LISTEN_PORT = 49361
export const LISTEN_PORT_RANGE_SIZE = 39
export const LISTEN_PORT_FILE = "server-port.json"
export const ANY_FREE_PORT = 0

export type ListenPortPlan =
  | { readonly kind: "pinned"; readonly port: number }
  | {
      readonly kind: "automatic"
      readonly preferred: number
      readonly lastUsed: number | undefined
    }

export interface ListenPortRecord {
  readonly port: number
  readonly pid: number
  readonly bootId: string
}

type Settings = Readonly<Record<string, string | undefined>>

export const resolveListenPortPlan = (
  args: Settings,
  env: Settings,
  lastUsed: number | undefined
): ListenPortPlan => {
  const pinned = nonEmpty(args["port"]) ?? nonEmpty(env["CODEVISOR_PORT"])
  if (pinned !== undefined) return { kind: "pinned", port: requirePort(pinned, "--port", 0) }

  return { kind: "automatic", preferred: preferredPort(args), lastUsed }
}

export const listenCandidates = (plan: ListenPortPlan): ReadonlyArray<number> => {
  if (plan.kind === "pinned") return [plan.port]

  const sticky = plan.lastUsed === undefined ? [] : [plan.lastUsed]
  return [...new Set([...sticky, ...portRange(plan.preferred), ANY_FREE_PORT])]
}

export const listenPortArgs = (plan: ListenPortPlan): ReadonlyArray<string> => {
  if (plan.kind === "pinned") return ["--port", String(plan.port)]
  if (plan.preferred === DEFAULT_LISTEN_PORT) return []
  return ["--preferred-port", String(plan.preferred)]
}

export const listenPortFile = (dataDir: string): string => join(dataDir, LISTEN_PORT_FILE)

export const parseListenPortFile = (contents: string | undefined): number | undefined => {
  const port = field(parseJson(contents), "port")
  return isServerPort(port) ? port : undefined
}

export const readListenPort = (dataDir: string): number | undefined => {
  const path = listenPortFile(dataDir)
  if (!existsSync(path)) return undefined
  return parseListenPortFile(readFileSync(path, "utf8"))
}

export const recordListenPort = (dataDir: string, record: ListenPortRecord): void => {
  writeJsonStateFile(listenPortFile(dataDir), record)
}

const MAX_PORT = 65_535

const portRange = (first: number): ReadonlyArray<number> =>
  Array.from({ length: LISTEN_PORT_RANGE_SIZE }, (_, offset) => first + offset).filter(
    (port) => port <= MAX_PORT
  )

const nonEmpty = (value: string | undefined): string | undefined =>
  value === undefined || value.trim() === "" ? undefined : value.trim()

const preferredPort = (args: Settings): number => {
  const raw = nonEmpty(args["preferred-port"])
  if (raw === undefined) return DEFAULT_LISTEN_PORT
  return requirePort(raw, "--preferred-port", 1)
}

const requirePort = (raw: string, flag: string, minimum: number): number => {
  const port = Number(raw)
  if (Number.isInteger(port) && port >= minimum && port <= MAX_PORT) return port
  throw new Error(`${flag} must be a port number from ${minimum} to ${MAX_PORT}, not "${raw}"`)
}

const isServerPort = (value: unknown): value is number =>
  typeof value === "number" && Number.isInteger(value) && value > 0 && value <= MAX_PORT

const parseJson = (contents: string | undefined): unknown => {
  if (contents === undefined) return undefined
  try {
    return JSON.parse(contents)
  } catch {
    return undefined
  }
}
