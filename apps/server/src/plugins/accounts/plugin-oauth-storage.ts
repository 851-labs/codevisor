import type { CodevisorDatabaseService } from "@codevisor/db"
import { openJson, sealJson } from "@codevisor/mcp"
import { Effect } from "effect"

import type { PendingOAuthStorage } from "./plugin-oauth-pending.js"

export const pendingOAuthSetting = "plugin-oauth-flows"

export const sealedPendingOAuthStorage = (
  db: CodevisorDatabaseService,
  key: Buffer
): PendingOAuthStorage => ({
  read: async () => {
    const sealed = await Effect.runPromise(db.getMachineSetting(pendingOAuthSetting))
    return sealed === undefined ? [] : openJson(key, sealed)
  },
  write: async (entries) => {
    const sealed = entries.length === 0 ? undefined : sealJson(key, entries)
    await Effect.runPromise(db.setMachineSetting(pendingOAuthSetting, sealed))
  }
})
