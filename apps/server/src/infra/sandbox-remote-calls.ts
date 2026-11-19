import { isRecord } from "@codevisor/api"

import type { SandboxDeps } from "./sandboxes.js"

const ATTEMPTS = 7
const PAUSE_MS = 5000

export interface SandboxCall {
  readonly machineId: string
  readonly tool: string
  readonly args: unknown
  readonly repeatable?: boolean
}

export const askSandbox = async (
  deps: Pick<SandboxDeps, "remoteTools" | "clock" | "log">,
  { machineId, tool, args, repeatable = false }: SandboxCall
): Promise<unknown> => {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await deps.remoteTools.call(machineId, tool, args)
    } catch (cause) {
      if (attempt >= ATTEMPTS || !canAskAgain(cause, repeatable)) throw cause
      deps.log(`Asking the sandbox for ${tool} again: ${messageOf(cause)}`)
      await deps.clock.sleep(PAUSE_MS)
    }
  }
}

const canAskAgain = (cause: unknown, repeatable: boolean): boolean => {
  if (field(cause, "code") !== "machine_unavailable") return false
  const phase = field(field(cause, "details"), "phase")
  return phase === "before-send" || (phase === "in-flight" && repeatable)
}

const field = (value: unknown, key: string): unknown => (isRecord(value) ? value[key] : undefined)

const messageOf = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)
