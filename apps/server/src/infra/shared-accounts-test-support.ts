import { randomUUID } from "node:crypto"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { coordinateCredential, type CredentialRecord } from "@codevisor/api"
import {
  makeSharedCredentialVault,
  type HarnessAuthManager,
  type SharedTokenBundle
} from "@codevisor/harness-manager"
import { onTestFinished, vi } from "vitest"

import { makeServices, run } from "../test-support.js"
import { SHARED_ACCOUNTS_NAMESPACE } from "./shared-account-store.js"
import { makeSharedAccounts } from "./shared-accounts.js"

export const native = (subject: string): SharedTokenBundle => ({
  harnessId: "codex",
  subject,
  email: `${subject}@example.test`,
  organizationId: "work",
  accessToken: `access-${subject}`,
  expiresAt: 10_000_000,
  ownership: "external"
})
export const fleet = () => {
  const records = new Map<string, CredentialRecord>()
  const rotate = vi.fn(async (bundle: SharedTokenBundle) => ({
    ...bundle,
    accessToken: "rotated",
    refreshToken: "rotated-refresh",
    expiresAt: 20_000_000
  }))
  const machine = async (
    id: string,
    initial?: SharedTokenBundle,
    overrides: Partial<Parameters<typeof makeSharedAccounts>[0]> = {}
  ) => {
    const { services } = await makeServices(id)
    const dataDir = await mkdtemp(join(tmpdir(), "shared-account-test-"))
    // The real Codex CLI keeps syncing its bundled skills into this HOME for
    // a moment after the test's last request; retry the removal instead of
    // failing on ENOTEMPTY when that write lands mid-delete.
    onTestFinished(() =>
      rm(dataDir, { force: true, maxRetries: 10, recursive: true, retryDelay: 100 })
    )
    let bundle = initial
    const receipts = new Map<string, { operationId: string; sealed: string }>()
    const vault = makeSharedCredentialVault({
      coordinate: async (key, command) => {
        const next = coordinateCredential(records.get(key), command, id, Date.now())
        if (next.record) records.set(key, next.record)
        return next.result
      },
      rotate,
      receipt: {
        read: async (key) => receipts.get(key),
        write: async (key, value) => {
          receipts.set(key, value)
        },
        remove: async (key) => {
          receipts.delete(key)
        }
      }
    })
    const auth = {
      subscribe: () => () => {},
      refresh: async () => {},
      beginLogin: vi.fn(async (id: string) => ({
        id: "flow",
        accountId: id,
        kind: "complete" as const
      })),
      answerLogin: vi.fn(async () => ({
        id: "flow",
        accountId: "account",
        kind: "complete" as const
      })),
      cancelLogin: vi.fn(async () => {}),
      createAccount: async (harnessId: string, label: string) =>
        run(
          services.db.saveHarnessAccount({
            id: randomUUID(),
            harnessId,
            label,
            profileKind: "managed",
            authState: "unauthenticated",
            canLogin: true,
            canLogout: false
          })
        )
    } as unknown as HarnessAuthManager
    const options = {
      db: services.db,
      auth,
      vault,
      dataDir,
      serverId: id,
      baseUrl: "http://127.0.0.1:1",
      environment: async () => ({ HOME: dataDir }),
      discover: async (
        harnessId: string,
        _directory: string,
        isDefault: boolean,
        managed: boolean
      ) => {
        if (harnessId !== bundle?.harnessId || (isDefault && bundle.ownership === "managed"))
          return undefined
        if (!isDefault && !managed) return undefined
        return bundle
      },
      ...overrides
    }
    const shared = makeSharedAccounts(options)
    return {
      shared,
      restart: () => makeSharedAccounts(options),
      vault,
      services: { ...services, auth, sharedAccounts: shared, credentialFerry: [] },
      auth,
      dataDir,
      db: services.db,
      setBundle: (next: SharedTokenBundle | undefined) => {
        bundle = next
      }
    }
  }
  const sync = async (
    from: Awaited<ReturnType<typeof machine>>,
    to: Awaited<ReturnType<typeof machine>>
  ) => {
    await run(to.db.mergeSyncEntries(SHARED_ACCOUNTS_NAMESPACE, await from.shared.store.entries()))
    await to.shared.reconcileRemote()
  }
  return { machine, sync, rotate, records }
}
