import type { SandboxSetupLog } from "@codevisor/api"

import type { SandboxSetupPublisher } from "./sandbox-setup-log.js"

export interface SandboxLogBook {
  readonly start: (id: string) => void
  readonly recording: (publish: SandboxSetupPublisher | undefined) => SandboxSetupPublisher
  readonly lines: (id: string, last?: number) => ReadonlyArray<SandboxSetupLog>
}

export const SANDBOX_LOG_LINES = 1000
export const SANDBOX_LOGS_KEPT = 32

export const makeSandboxLogBook = (): SandboxLogBook => {
  const logs = new Map<string, SandboxSetupLog[]>()

  const start = (id: string): void => {
    logs.delete(id)
    logs.set(id, [])
    forgetOldest(logs)
  }

  const record = (log: SandboxSetupLog): void => {
    const lines = logs.get(log.machineId)
    if (lines === undefined) return
    lines.push(log)
    if (lines.length > SANDBOX_LOG_LINES) lines.splice(0, lines.length - SANDBOX_LOG_LINES)
  }

  return {
    start,
    recording: (publish) => async (log) => {
      record(log)
      await publish?.(log)
    },
    lines: (id, last = SANDBOX_LOG_LINES) => (logs.get(id) ?? []).slice(-last)
  }
}

const forgetOldest = (logs: Map<string, unknown>): void => {
  for (const id of logs.keys()) {
    if (logs.size <= SANDBOX_LOGS_KEPT) return
    logs.delete(id)
  }
}
