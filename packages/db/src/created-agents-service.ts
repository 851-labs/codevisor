import type { Effect } from "effect"

import { idRows } from "./common-rows.js"
import { attempt, type DatabaseError } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import type { ServiceContext } from "./service-context.js"

export interface CreatedAgentsMove {
  readonly fromAgentId: string
  readonly toAgentId: string
  readonly creatorMachineId: string
  readonly toMachineId?: string | undefined
}

export interface CreatedAgentsService {
  readonly moveCreatedAgents: (
    move: CreatedAgentsMove
  ) => Effect.Effect<ReadonlyArray<string>, DatabaseError>
}

export const makeCreatedAgentsService = (context: ServiceContext): CreatedAgentsService => ({
  moveCreatedAgents: (move) =>
    attempt("moveCreatedAgents", () => {
      const { sqlite } = context
      const from = canonicalUuid(move.fromAgentId)
      const to = canonicalUuid(move.toAgentId)
      return sqlite.transaction(() => {
        const ids = idRows
          .all(sqlite.prepare(createdAgentsSql.created).all(from, move.creatorMachineId))
          .map((row) => row.id)
        const toMachineId = move.toMachineId ?? move.creatorMachineId
        sqlite.prepare(createdAgentsSql.move).run(to, toMachineId, from, move.creatorMachineId)
        return ids
      })()
    })
})

const createdAgentsSql = {
  created: `select id from sessions
              where created_by_agent_id = ? collate nocase and created_by_agent_machine_id = ?
              order by created_at asc`,
  move: `update sessions set created_by_agent_id = ?, created_by_agent_machine_id = ?
           where created_by_agent_id = ? collate nocase and created_by_agent_machine_id = ?`
}
