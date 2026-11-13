import type { Migration } from "./migration-types.js"

const now = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"

const claudeDefaultAccounts = `
  select id from harness_accounts
    where harness_id = 'claude-code' and profile_kind = 'default' and removed_at is null
`

export const migrations105: ReadonlyArray<Migration> = [
  {
    id: 105,
    name: "claude runs only on accounts codevisor manages, never the machine's own claude profile",
    sql: `
      update sessions set harness_account_id = null
        where harness_account_id in (${claudeDefaultAccounts});
      delete from harness_account_selection
        where account_id in (${claudeDefaultAccounts});
      update harness_accounts set removed_at = ${now}, updated_at = ${now}
        where id in (${claudeDefaultAccounts});
    `
  }
]
