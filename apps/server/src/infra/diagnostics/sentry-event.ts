import { randomUUID } from "node:crypto"

import { scrubDiagnosticText } from "./scrub.js"
import { parseStackFrames, type StackFrame } from "./stack-frames.js"

export interface DiagnosticReport {
  readonly component: string
  readonly groupBy?: string
  readonly tags?: Readonly<Record<string, string>>
}

export interface DiagnosticEnvironment {
  readonly release: string
  readonly environment: string
  readonly tags: Readonly<Record<string, string>>
}

export interface SentryException {
  readonly type: string
  readonly value: string
  readonly stacktrace?: { readonly frames: ReadonlyArray<StackFrame> }
}

export interface SentryEvent {
  readonly event_id: string
  readonly timestamp: number
  readonly platform: "node"
  readonly level: "error"
  readonly release: string
  readonly environment: string
  readonly tags: Readonly<Record<string, string>>
  readonly fingerprint: ReadonlyArray<string>
  readonly exception: { readonly values: ReadonlyArray<SentryException> }
}

export const buildSentryEvent = (
  cause: unknown,
  report: DiagnosticReport,
  environment: DiagnosticEnvironment,
  now: number
): SentryEvent => ({
  event_id: randomUUID().replaceAll("-", ""),
  timestamp: now / 1_000,
  platform: "node",
  level: "error",
  release: environment.release,
  environment: environment.environment,
  tags: { ...environment.tags, ...report.tags, component: report.component },
  fingerprint: fingerprint(report),
  exception: { values: causeChain(cause).map(toException).toReversed() }
})

const fingerprint = (report: DiagnosticReport): ReadonlyArray<string> =>
  report.groupBy === undefined
    ? ["{{ default }}", report.component]
    : [report.component, scrubDiagnosticText(report.groupBy)]

const maxLinkedCauses = 3

const causeChain = (cause: unknown): ReadonlyArray<unknown> => {
  const chain: unknown[] = [cause]
  let current = cause
  while (
    current instanceof Error &&
    current.cause !== undefined &&
    chain.length <= maxLinkedCauses
  ) {
    current = current.cause
    chain.push(current)
  }
  return chain
}

const toException = (cause: unknown): SentryException => {
  if (!(cause instanceof Error))
    return { type: "NonError", value: scrubDiagnosticText(String(cause)) }

  const frames = parseStackFrames(cause.stack)
  return {
    type: cause.name,
    value: scrubDiagnosticText(cause.message),
    ...(frames.length === 0 ? {} : { stacktrace: { frames } })
  }
}
