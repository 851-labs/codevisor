import { join } from "node:path"

import type { CodevisorDatabaseService, HarnessAccountRecord } from "@codevisor/db"
import { Effect } from "effect"

import { failureMessage } from "../server-context.js"
import type { SharedAccountLocalState } from "./shared-account-local-state.js"

export type ForgetProfileLogin = (directory: string, env: NodeJS.ProcessEnv) => Promise<boolean>

export interface ClaudeProfileLoginsDeps {
  readonly db: CodevisorDatabaseService
  readonly dataDir: string
  readonly localState: SharedAccountLocalState
  readonly environment: () => Promise<NodeJS.ProcessEnv>
  readonly forget: ForgetProfileLogin
}

export const makeClaudeProfileLogins = (deps: ClaudeProfileLoginsDeps) => {
  const checkedAt = new Map<string, number>()
  let swept = false

  const clear = async (directory: string): Promise<void> => {
    try {
      if (await deps.forget(directory, await deps.environment()))
        console.error(`Removed a duplicate Claude sign-in from ${directory}`)
    } catch (cause) {
      console.error(`Could not remove the Claude sign-in in ${directory}: ${failureMessage(cause)}`)
    }
  }

  const clearUnlessRecent = async (directory: string): Promise<void> => {
    const now = Date.now()
    if (now - (checkedAt.get(directory) ?? -Infinity) < sessionProfileCheckIntervalMs) return

    checkedAt.set(directory, now)
    await clear(directory)
  }

  const retiredProfiles = async (): Promise<ReadonlyArray<HarnessAccountRecord>> => {
    const rows = await Effect.runPromise(deps.db.listHarnessAccounts("claude-code"))
    const retired: HarnessAccountRecord[] = []
    for (const row of rows) if (await isRetired(row, deps.localState)) retired.push(row)
    return retired
  }

  return {
    afterCapture: (row: HarnessAccountRecord) => clear(profileDirectory(deps.dataDir, row)),
    beforeSession: (accountId: string) =>
      clearUnlessRecent(join(claudeProfiles(deps.dataDir), accountId)),
    sweepOnce: async (): Promise<void> => {
      if (swept) return
      swept = true

      for (const row of await retiredProfiles()) await clear(profileDirectory(deps.dataDir, row))
    }
  }
}

export type ClaudeProfileLogins = ReturnType<typeof makeClaudeProfileLogins>

const sessionProfileCheckIntervalMs = 5 * 60_000

const claudeProfiles = (dataDir: string): string => join(dataDir, "harness-profiles", "claude-code")

const profileDirectory = (dataDir: string, row: HarnessAccountRecord): string =>
  join(claudeProfiles(dataDir), row.profileKey ?? row.id)

const isRetired = async (
  row: HarnessAccountRecord,
  localState: SharedAccountLocalState
): Promise<boolean> => {
  if (row.profileKind !== "managed") return false
  if (row.id.startsWith("shared-")) return true
  return localState.hasAlias(row.id)
}
