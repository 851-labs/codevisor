import { homedir } from "node:os"
import { join } from "node:path"

import type { CodevisorDatabaseService, HarnessAccountRecord } from "@codevisor/db"
import { Effect } from "effect"

import type { SharedAccountImports } from "./shared-account-imports.js"
import type { LocalAccountRows } from "./shared-account-local-rows.js"
import type { SharedAccountLocalState } from "./shared-account-local-state.js"
import type { ClaudeProfileLogins } from "./shared-account-profile-logins.js"
import type { discoverNativeAccount } from "./shared-account-storage.js"
import type { SharedAccountStore } from "./shared-account-store.js"

export interface SharedAccountReconcileDeps {
  readonly db: CodevisorDatabaseService
  readonly store: SharedAccountStore
  readonly localState: SharedAccountLocalState
  readonly localRows: LocalAccountRows
  readonly imports: SharedAccountImports
  readonly profileLogins: ClaudeProfileLogins
  readonly providers: { readonly reconcile: () => Promise<void> }
  readonly environment: () => Promise<NodeJS.ProcessEnv>
  readonly discover: typeof discoverNativeAccount
}

export const makeSharedAccountReconcile = (deps: SharedAccountReconcileDeps) => {
  const { db, store, localState, localRows, imports } = deps
  let reconciling: Promise<void> | undefined

  const reconcile = (): Promise<void> => {
    reconciling ??= (async () => {
      for (const harnessId of machineLoginHarnesses) {
        const env = await deps.environment()
        try {
          const rows = await run(db.listHarnessAccounts(harnessId))
          const nativeId = rows.find((row) => row.profileKind === "default")?.id
          if (harnessId === "claude-code") await imports.adoptClaudeMachineLogin(env, nativeId)
          else {
            const bundle = await deps.discover(harnessId, codexHome(env), true, false, env)
            if (bundle) await imports.importBundle(bundle, nativeId)
          }

          for (const row of rows.filter((candidate) => isAdoptableProfile(candidate, localState))) {
            if (await localState.hasAlias(row.id)) continue
            if ((await localState.loginTarget(row.id)) !== undefined) {
              const saved = await imports.nativeBundle(row, true)
              if (saved?.refreshToken) await imports.captureLogin(row.id)
              continue
            }

            const existing = await imports.nativeBundle(row, true)
            if (existing) await imports.importBundle(existing, row.id, false, row.label)
          }
        } catch {}
      }

      try {
        for (const row of await run(db.listHarnessAccounts("antigravity"))) {
          if (!isAdoptableProfile(row, localState)) continue
          if (await localState.hasAlias(row.id)) continue
          if ((await localState.loginTarget(row.id)) !== undefined) continue

          const existing = await imports.nativeBundle(row, true)
          if (existing) await imports.importBundle(existing, row.id, false, row.label)
        }
      } catch {}

      await deps.profileLogins.sweepOnce()
      for (const account of await store.accounts()) await localRows.save(account)
      for (const harnessId of selectableHarnesses) await localRows.applySelection(harnessId)
      await deps.providers.reconcile()
    })().finally(() => {
      reconciling = undefined
    })
    return reconciling
  }
  return reconcile
}

const run = Effect.runPromise

const machineLoginHarnesses = ["claude-code", "codex"] as const

const selectableHarnesses = ["claude-code", "codex", "muse-code", "antigravity"]

const isAdoptableProfile = (
  row: HarnessAccountRecord,
  localState: SharedAccountLocalState
): boolean =>
  row.profileKind === "managed" &&
  !row.id.startsWith("shared-") &&
  !localState.isCapturingLogin(row.id)

const codexHome = (env: NodeJS.ProcessEnv): string =>
  env.CODEX_HOME ?? join(env.HOME ?? homedir(), ".codex")
