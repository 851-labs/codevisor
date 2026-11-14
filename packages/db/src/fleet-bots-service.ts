import type { FleetBot } from "@codevisor/api"
import type { Effect } from "effect"

import { attempt, type DatabaseError } from "./errors.js"
import { nullable, rowReader, text } from "./row-reader.js"
import type { ServiceContext } from "./service-context.js"

export interface FleetBotsMachine {
  readonly machineId: string
  readonly machineName: string
}

export interface FleetBotRecord {
  readonly botId: string
  readonly name: string
  readonly about?: string | undefined
}

export interface FleetBotsService {
  readonly listFleetBots: Effect.Effect<ReadonlyArray<FleetBot>, DatabaseError>
  readonly replaceFleetBots: (
    machine: FleetBotsMachine,
    bots: ReadonlyArray<FleetBotRecord>
  ) => Effect.Effect<void, DatabaseError>
}

export const makeFleetBotsService = ({ sqlite }: ServiceContext): FleetBotsService => ({
  listFleetBots: attempt("listFleetBots", () =>
    fleetBotRows.all(sqlite.prepare(fleetBotSql.list).all()).map((row) => ({
      machineId: row.machine_id,
      machineName: row.machine_name,
      botId: row.bot_id,
      name: row.name,
      ...(row.about === null || row.about === "" ? {} : { about: row.about })
    }))
  ),
  replaceFleetBots: (machine, bots) =>
    attempt("replaceFleetBots", () =>
      sqlite.transaction(() => {
        sqlite.prepare(fleetBotSql.clear).run(machine.machineId)
        const insert = sqlite.prepare(fleetBotSql.insert)
        for (const bot of bots) {
          insert.run(machine.machineId, bot.botId, machine.machineName, bot.name, bot.about ?? null)
        }
      })()
    )
})

const fleetBotRows = rowReader({
  machine_id: text,
  bot_id: text,
  machine_name: text,
  name: text,
  about: nullable(text)
})

const fleetBotSql = {
  list: "select * from fleet_bots order by machine_name, name, bot_id",
  clear: "delete from fleet_bots where machine_id = ?",
  insert: `insert into fleet_bots (machine_id, bot_id, machine_name, name, about)
      values (?, ?, ?, ?, ?)`
}
