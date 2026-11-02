import { mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs"
import { dirname } from "node:path"

import type { UpdateApplyState } from "@codevisor/api"
import { readAppUpdateApplyState } from "@codevisor/updater"

export const APP_HANDOFF_TIMEOUT_MS = 30_000
export const APP_HANDOFF_POLL_MS = 500
export const HOST_APP_SILENT_MESSAGE =
  "Codevisor isn't open on this Mac, so it couldn't install the update. Open Codevisor on this Mac, then try again."

export interface AppHandoff {
  readonly requestPath: string
  readonly dataDir: string
  readonly version: string
}

export const handOffToHostApp = async (handoff: AppHandoff): Promise<void> => {
  const requestedAt = Date.now()
  writeAppUpdateRequest(handoff.requestPath, handoff.version)
  if (await hostAppResponds(handoff.dataDir, requestedAt)) return

  rmSync(handoff.requestPath, { force: true })
  throw new Error(HOST_APP_SILENT_MESSAGE)
}

export const failedApply = (cause: unknown): UpdateApplyState => ({
  state: "failed",
  message: cause instanceof Error ? cause.message : String(cause),
  at: new Date().toISOString()
})

export const latestApplyState = (
  ...states: ReadonlyArray<UpdateApplyState | undefined>
): UpdateApplyState | undefined =>
  states
    .filter((state): state is UpdateApplyState => state !== undefined)
    .reduce<UpdateApplyState | undefined>(
      (latest, state) => (latest === undefined || isLater(state, latest) ? state : latest),
      undefined
    )

const hostAppResponds = async (dataDir: string, requestedAt: number): Promise<boolean> => {
  const deadline = requestedAt + APP_HANDOFF_TIMEOUT_MS
  while (!reportedSince(dataDir, requestedAt)) {
    if (Date.now() >= deadline) return false
    await pause(APP_HANDOFF_POLL_MS)
  }
  return true
}

const reportedSince = (dataDir: string, requestedAt: number): boolean => {
  const reported = readAppUpdateApplyState(dataDir)
  return reported !== undefined && Date.parse(reported.at) >= requestedAt
}

const writeAppUpdateRequest = (path: string, version: string): void => {
  mkdirSync(dirname(path), { recursive: true })
  const temporary = `${path}.${process.pid}.tmp`
  writeFileSync(
    temporary,
    `${JSON.stringify({ version, requestedAt: new Date().toISOString(), pid: process.pid })}\n`,
    { encoding: "utf8", mode: 0o600 }
  )
  renameSync(temporary, path)
}

const isLater = (state: UpdateApplyState, other: UpdateApplyState): boolean =>
  Date.parse(state.at) > Date.parse(other.at)

const pause = (milliseconds: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, milliseconds))
