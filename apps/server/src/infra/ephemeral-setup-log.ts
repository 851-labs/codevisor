import type { EphemeralSetupLog, EphemeralSetupStage, EphemeralSetupStep } from "@codevisor/api"
import { SIGN_IN_MARKER, type OutputStream } from "@codevisor/ephemeral-machines"

export type EphemeralSetupPublisher = (log: EphemeralSetupLog) => Promise<void>

export interface EphemeralSetupProgress {
  readonly stage: (stage: EphemeralSetupStage) => void
  readonly log: (line: string, stream?: OutputStream) => void
  readonly output: (stream: OutputStream, text: string) => void
  readonly flush: () => void
  readonly redact: (secret: string) => void
  readonly finish: () => void
}

export interface EphemeralSetupProgressOptions {
  readonly machineId: string
  readonly now: () => string
  readonly persist: (steps: ReadonlyArray<EphemeralSetupStep>) => void
  readonly publish?: EphemeralSetupPublisher | undefined
}

const maxLineLength = 2000
const ansiEscape = new RegExp(`${String.fromCharCode(27)}\\[[0-9;?]*[A-Za-z]`, "g")
const lineBreak = /\r\n|\r|\n/

export const makeEphemeralSetupProgress = (
  options: EphemeralSetupProgressOptions
): EphemeralSetupProgress => {
  const steps: EphemeralSetupStep[] = []
  const secrets: string[] = []
  const pending: Record<OutputStream, string> = { stdout: "", stderr: "" }
  let published: Promise<void> = Promise.resolve()

  const closeCurrent = (at: string): void => {
    const last = steps.at(-1)
    if (last === undefined || last.endedAt !== undefined) return
    steps[steps.length - 1] = { ...last, endedAt: at }
  }

  const stage = (next: EphemeralSetupStage): void => {
    const at = options.now()
    closeCurrent(at)
    steps.push({ stage: next, startedAt: at })
    options.persist([...steps])
  }

  const log = (raw: string, stream: OutputStream = "stdout"): void => {
    const line = cleaned(raw, secrets)
    const current = steps.at(-1)?.stage
    if (line === "" || current === undefined || options.publish === undefined) return

    const publish = options.publish
    const event = { machineId: options.machineId, stage: current, stream, line }
    published = published.then(() => publish(event)).catch(() => undefined)
  }

  const consume = (stream: OutputStream, line: string): void => {
    if (line.trim() === SIGN_IN_MARKER) stage("signIn")
    else log(line, stream)
  }

  return {
    stage,
    log,
    output: (stream, text) => {
      const lines = (pending[stream] + text).split(lineBreak)
      pending[stream] = lines.splice(-1).join("")
      for (const line of lines) consume(stream, line)
    },
    flush: () => {
      for (const stream of ["stdout", "stderr"] as const) {
        const rest = pending[stream]
        pending[stream] = ""
        if (rest !== "") consume(stream, rest)
      }
    },
    redact: (secret) => {
      if (secret !== "") secrets.push(secret)
    },
    finish: () => {
      closeCurrent(options.now())
      options.persist([...steps])
    }
  }
}

const cleaned = (raw: string, secrets: ReadonlyArray<string>): string => {
  let line = raw.replace(ansiEscape, "").trimEnd()
  for (const secret of secrets) line = line.replaceAll(secret, "[invite]")
  return line.slice(0, maxLineLength)
}
