import type { HarnessAccount } from "@codevisor/api"
import { chmod, mkdir, rm } from "node:fs/promises"
import { randomUUID } from "node:crypto"
import { join } from "node:path"
import type { HarnessAuthCore } from "./harness-auth-core.js"
import type { HarnessAuthDecoration } from "./harness-auth-decoration.js"
import type { HarnessAuthProbes } from "./harness-auth-probes.js"
import { run } from "./harness-auth-support.js"
import type { HarnessAuthManager } from "./harness-auth-types.js"

export type HarnessAccountOperations = Pick<
  HarnessAuthManager,
  "activateAccount" | "createAccount" | "removeAccount" | "renameAccount"
>

/// Managed-account bookkeeping: creating and naming isolated profiles,
/// removing them with their secrets, and switching the active account.
export const makeHarnessAccountOperations = (
  core: HarnessAuthCore,
  probes: HarnessAuthProbes,
  decoration: HarnessAuthDecoration
): HarnessAccountOperations => {
  const { apiKeyPath, config, definition, emit, profilePath, publicAccount } = core
  const { probeAccount } = probes
  const { authSnapshot } = decoration

  const createAccount = async (harnessId: string, label?: string): Promise<HarnessAccount> => {
    if (harnessId !== "codex" && harnessId !== "claude-code" && harnessId !== "opencode") {
      throw new Error("This harness does not support multiple managed accounts")
    }
    definition(harnessId)
    const id = randomUUID()
    const path = join(config.dataDir, "harness-profiles", harnessId, id)
    await mkdir(path, { recursive: true, mode: 0o700 })
    await chmod(path, 0o700)
    const saved = await run(
      config.db.saveHarnessAccount({
        id,
        harnessId,
        profileKind: "managed",
        profileKey: id,
        label:
          label?.trim() ||
          (harnessId === "opencode"
            ? `OpenCode profile ${id.slice(0, 6)}`
            : `Account ${id.slice(0, 6)}`),
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false
      })
    )
    const account = publicAccount(saved)
    emit({ kind: "harness.account.updated", subjectId: harnessId, payload: account })
    return account
  }

  const renameAccount = async (accountId: string, label: string): Promise<HarnessAccount> => {
    const account = await run(config.db.getHarnessAccount(accountId))
    if (account === undefined) throw new Error(`Harness account not found: ${accountId}`)
    const saved = await run(
      config.db.updateHarnessAccountAuth(accountId, {
        label: label.trim() || account.label,
        authState: account.authState
      })
    )
    const value = publicAccount(saved)
    emit({ kind: "harness.account.updated", subjectId: account.harnessId, payload: value })
    return value
  }

  const removeAccount = async (accountId: string): Promise<void> => {
    const account = await run(config.db.getHarnessAccount(accountId))
    if (account === undefined) throw new Error(`Harness account not found: ${accountId}`)
    const path = profilePath(account)
    await run(config.db.removeHarnessAccount(accountId))
    if (path !== undefined) await rm(path, { recursive: true, force: true })
    await rm(join(apiKeyPath(account), ".."), { recursive: true, force: true })
    emit({
      kind: "harness.account.updated",
      subjectId: account.harnessId,
      payload: { id: accountId, removed: true }
    })
  }

  const activateAccount = async (harnessId: string, accountId: string): Promise<void> => {
    const account = await probeAccount(accountId, true)
    if (account.harnessId !== harnessId) throw new Error("Account belongs to another harness")
    if (account.authState !== "authenticated" && account.authState !== "notRequired") {
      throw new Error("Sign in to this account before selecting it")
    }
    await run(config.db.setActiveHarnessAccount(harnessId, accountId))
    // Claude account selection applies to every chat on its next turn. A turn
    // already running keeps its live process and finishes on the previous
    // account; the runtime reloads the session with this binding before the
    // next prompt. Usage limits leave an exhausted account authenticated, so
    // Claude cannot rely on the dead-account sweep used by other harnesses.
    const rebindAuthenticatedSiblings = harnessId === "claude-code"
    const siblings = await run(config.db.listHarnessAccounts(harnessId))
    await Promise.all(
      siblings
        .filter(
          (sibling) =>
            sibling.id !== accountId &&
            (rebindAuthenticatedSiblings ||
              (sibling.authState !== "authenticated" && sibling.authState !== "notRequired"))
        )
        .map((sibling) => run(config.db.rebindHarnessAccountSessions(sibling.id, accountId)))
    )
    emit({
      kind: "harness.auth.updated",
      subjectId: harnessId,
      payload: await authSnapshot(harnessId)
    })
  }

  return { activateAccount, createAccount, removeAccount, renameAccount }
}
