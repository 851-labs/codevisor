import type { Migration } from "./migration-types.js"

export const migrations57: ReadonlyArray<Migration> = [
  {
    id: 57,
    name: "unavailable session config selections",
    // Saved picker values the chat's runtime no longer offers. The saved pick
    // stays in `config_selections` (the user's choice is never overwritten by
    // a runtime fallback); this column records which of them could not be
    // applied so clients can say so.
    //
    // The navigation trigger lists the session columns it watches and is
    // created "if not exists"; dropping it lets installNavigationJournal
    // recreate it with this column after the schema commit.
    sql: `
      alter table sessions add column unavailable_config_selections text not null default '{}';
      drop trigger if exists navigation_sessions_update;
    `
  }
]
