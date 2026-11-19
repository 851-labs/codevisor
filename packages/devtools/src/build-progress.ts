import { spawn, type SpawnOptions } from "node:child_process"
import { createInterface } from "node:readline"
import type { Readable } from "node:stream"

import { describeExit, waitForClose } from "./child-processes.ts"

export interface BuildProgress {
  readonly line: (text: string) => void
  readonly heartbeat: () => void
}

interface Phase {
  readonly name: string
  readonly startedAt: number
  readonly crates: number
}

export const phaseMarker = "==> "
const heartbeatMs = 20_000
const compilingCrate = /^\s*Compiling\s/
const downloadedCrate = /^\s*Downloaded\s+\S+\s+v\d/

export async function runWithProgress(
  command: string,
  args: ReadonlyArray<string>,
  options: SpawnOptions = {},
  phase?: string
): Promise<void> {
  const progress = createBuildProgress((line) => console.log(line))
  if (phase !== undefined) progress.line(`${phaseMarker}${phase}`)

  const child = spawn(command, args, { ...options, stdio: ["ignore", "pipe", "pipe"] })
  const heartbeat = setInterval(progress.heartbeat, heartbeatMs)
  try {
    forwardLines(child.stdout, progress.line)
    forwardLines(child.stderr, progress.line)
    const result = await waitForClose(child)
    if (result.code !== 0) throw new Error(`${command} failed (${describeExit(result)})`)
  } finally {
    clearInterval(heartbeat)
  }
}

export function createBuildProgress(
  write: (line: string) => void,
  now: () => number = Date.now
): BuildProgress {
  let phase: Phase = { name: "Building", startedAt: now(), crates: 0 }
  return {
    line: (text) => {
      if (compilingCrate.test(text)) {
        phase = { ...phase, crates: phase.crates + 1 }
        return
      }
      if (downloadedCrate.test(text)) return

      if (text.startsWith(phaseMarker))
        phase = { name: text.slice(phaseMarker.length), startedAt: now(), crates: 0 }
      write(text)
    },
    heartbeat: () => write(describePhase(phase, now()))
  }
}

export function formatElapsed(milliseconds: number): string {
  const seconds = Math.floor(milliseconds / 1000)
  const minutes = Math.floor(seconds / 60)
  if (minutes === 0) return `${seconds}s`

  return `${minutes}m ${seconds % 60}s`
}

function describePhase(phase: Phase, now: number): string {
  const elapsed = formatElapsed(now - phase.startedAt)
  if (phase.crates === 0) return `    ${phase.name}: still working, ${elapsed}`

  return `    ${phase.name}: ${phase.crates} crates so far, ${elapsed}`
}

function forwardLines(stream: Readable | null, line: (text: string) => void): void {
  if (stream !== null) createInterface({ input: stream }).on("line", line)
}
