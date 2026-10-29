import type { CodevisorDatabaseService } from "@codevisor/db"
import { Schema } from "effect"

import { run } from "../server-context.js"
import { StoredSandboxAccount, type SandboxSettings } from "./sandbox-settings.js"

export interface RetainedAccounts {
  readonly account: (id: string) => Promise<StoredSandboxAccount | undefined>
  readonly exists: (id: string) => Promise<boolean>
  readonly retain: (ids: ReadonlySet<string>) => Promise<void>
}

type MachineSettings = Pick<CodevisorDatabaseService, "getMachineSetting" | "setMachineSetting">

const retainedKey = "sandbox-retained-accounts"
const decodeRetained = Schema.decodeUnknownSync(
  Schema.fromJsonString(Schema.Array(StoredSandboxAccount))
)

export const makeRetainedAccounts = (
  db: MachineSettings,
  settings: Pick<SandboxSettings, "account">
): RetainedAccounts => {
  const list = async (): Promise<ReadonlyArray<StoredSandboxAccount>> => {
    const stored = await run(db.getMachineSetting(retainedKey))
    return stored === undefined ? [] : decodeRetained(stored)
  }
  const retainedById = async (id: string) => (await list()).find((account) => account.id === id)
  const current = async (id: string) => (await settings.account(id)) ?? (await retainedById(id))
  return {
    account: current,
    exists: async (id) => (await settings.account(id)) !== undefined,
    retain: async (ids) => {
      const kept = await Promise.all([...ids].map(current))
      const accounts = kept.filter((account) => account !== undefined)
      await run(db.setMachineSetting(retainedKey, JSON.stringify(accounts)))
    }
  }
}
