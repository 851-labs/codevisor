import { scrubDiagnosticText } from "./scrub.js"
import {
  buildSentryEvent,
  type DiagnosticEnvironment,
  type DiagnosticReport
} from "./sentry-event.js"
import type { SendSentryEvent } from "./sentry-transport.js"

export type { DiagnosticReport } from "./sentry-event.js"

export interface DiagnosticsSettings {
  readonly enabled: () => Promise<boolean>
  readonly enabledFlags: () => Promise<ReadonlySet<string>>
  readonly updateChannel: () => Promise<string>
}

export interface ServerDiagnosticsOptions {
  readonly settings: DiagnosticsSettings
  readonly environment: DiagnosticEnvironment
  readonly send: SendSentryEvent
  readonly now?: () => number
}

export interface ServerDiagnostics {
  readonly capture: (cause: unknown, report: DiagnosticReport) => Promise<void>
}

export const flagTagPrefix = "flag_"

export const makeServerDiagnostics = (options: ServerDiagnosticsOptions): ServerDiagnostics => {
  const now = options.now ?? Date.now
  const limiter = makeRateLimiter(now)
  const deliver = async (cause: unknown, report: DiagnosticReport): Promise<void> => {
    if (!(await options.settings.enabled())) return
    if (!limiter.admits(reportKey(cause, report))) return

    const environment = withTags(options.environment, await contextTags(options.settings))
    await options.send(buildSentryEvent(cause, report, environment, now()))
  }
  return { capture: (cause, report) => deliver(cause, report).catch(() => undefined) }
}

export const installServerDiagnostics = (diagnostics: ServerDiagnostics | undefined): void => {
  installed = diagnostics
}

export const serverDiagnosticsInstalled = (): boolean => installed !== undefined

export const reportServerError = (cause: unknown, report: DiagnosticReport): void => {
  void installed?.capture(cause, report)
}

let installed: ServerDiagnostics | undefined

const rateWindowMs = 10 * 60_000
const maxReportsPerWindow = 20
const reportKeyLength = 160

interface RateLimiter {
  readonly admits: (key: string) => boolean
}

const makeRateLimiter = (now: () => number): RateLimiter => {
  let windowStart = Number.NEGATIVE_INFINITY
  let seen = new Set<string>()
  return {
    admits: (key) => {
      if (now() - windowStart >= rateWindowMs) {
        windowStart = now()
        seen = new Set()
      }
      if (seen.has(key) || seen.size >= maxReportsPerWindow) return false
      seen.add(key)
      return true
    }
  }
}

const reportKey = (cause: unknown, report: DiagnosticReport): string => {
  const summary = cause instanceof Error ? `${cause.name}: ${cause.message}` : String(cause)
  return `${report.component} ${scrubDiagnosticText(summary)}`.slice(0, reportKeyLength)
}

const contextTags = async (settings: DiagnosticsSettings): Promise<Record<string, string>> => {
  const flags = [...(await settings.enabledFlags())].toSorted()
  return {
    update_channel: await settings.updateChannel(),
    feature_flags: flags.join(","),
    ...Object.fromEntries(flags.map((flag) => [`${flagTagPrefix}${flag}`, "true"]))
  }
}

const withTags = (
  environment: DiagnosticEnvironment,
  tags: Readonly<Record<string, string>>
): DiagnosticEnvironment => ({ ...environment, tags: { ...environment.tags, ...tags } })
