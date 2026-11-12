import type { Migration } from "./migration-types.js"

export const migrations103: ReadonlyArray<Migration> = [
  {
    id: 103,
    name: "every machine uses the shared harness accounts, with no machine-only overrides",
    sql: `
      delete from sync_entries where namespace = 'local.harness-account-overrides';
      delete from sync_entries
        where namespace = 'local.shared-accounts' and key like 'disabled:%';
      delete from sync_entries
        where namespace = 'local.shared-provider-accounts' and key like 'provider:%';
    `
  }
]
