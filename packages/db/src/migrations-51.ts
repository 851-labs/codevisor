import type { Migration } from "./migration-types.js"

export const migrations51: ReadonlyArray<Migration> = [
  {
    id: 51,
    name: "plan section timestamps on assistant chat items",
    // A plan splits one assistant turn into two "Worked for…" sections: the
    // planning before the proposed plan and the work that resumes after the
    // user answers it (Claude continues the same turn). Each section reports
    // its own duration, which the turn's started_at/completed_at cannot
    // express. The event journal that holds per-event times is pruned, so
    // the boundaries are recorded on the item when the events are projected.
    sql: `
      alter table chat_items add column plan_proposed_at text;
      alter table chat_items add column plan_resumed_at text;
    `
  }
]
