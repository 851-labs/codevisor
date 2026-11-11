import type { Migration } from "./migration-types.js"

export const migrations98: ReadonlyArray<Migration> = [
  {
    id: 98,
    name: "messages name the agent that sent them, and its machine",
    sql: `
      alter table prompt_queue_items add column sent_by_agent_id text;
      alter table prompt_queue_items add column sent_by_agent_machine_id text;
      alter table chat_items add column sent_by_agent_id text;
      alter table chat_items add column sent_by_agent_machine_id text;
    `
  }
]
