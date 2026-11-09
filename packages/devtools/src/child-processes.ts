import type { ChildProcess } from "node:child_process"

export interface ExitStatus {
  readonly code: number | null
  readonly signal: NodeJS.Signals | null
}

export function waitForExit(child: ChildProcess): Promise<ExitStatus> {
  if (child.exitCode !== null || child.signalCode !== null) {
    return Promise.resolve({ code: child.exitCode, signal: child.signalCode })
  }
  return new Promise((resolve) => {
    child.once("exit", (code, signal) => resolve({ code, signal }))
  })
}

export function waitForClose(child: ChildProcess): Promise<ExitStatus> {
  return new Promise((resolve) => {
    child.once("close", (code, signal) => resolve({ code, signal }))
  })
}

export function describeExit({ code, signal }: ExitStatus): string {
  return signal === null ? `code ${code ?? 1}` : `signal ${signal}`
}

export function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds))
}
