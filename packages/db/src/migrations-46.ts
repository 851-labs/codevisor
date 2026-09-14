import type { Migration } from "./migration-types.js"

export const migrations46: ReadonlyArray<Migration> = [
  {
    id: 46,
    name: "Codevisor built-in MCP provider",
    // Replace the column to widen its CHECK while preserving MCP records,
    // credentials, and the project/session settings that reference them.
    sql: `
      alter table mcp_servers add column next_kind text not null default 'managed'
        check(next_kind in ('managed', 'browserUse', 'computerUse', 'codevisor'));
      update mcp_servers set next_kind = kind;
      alter table mcp_servers drop column kind;
      alter table mcp_servers rename column next_kind to kind;
    `
  }
]
