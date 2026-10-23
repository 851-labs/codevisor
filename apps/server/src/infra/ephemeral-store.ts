import {
  EphemeralMachine,
  EphemeralProjectOptions,
  type EphemeralProjectOptions as ProjectOptions
} from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { Schema } from "effect"

import { run } from "../server-context.js"

export interface EphemeralRecordStore {
  readonly list: () => Promise<ReadonlyArray<EphemeralMachine>>
  readonly get: (id: string) => Promise<EphemeralMachine | undefined>
  readonly put: (machine: EphemeralMachine) => Promise<void>
  readonly remove: (id: string) => Promise<void>
  readonly projectOptions: (projectId: string) => Promise<ProjectOptions>
  readonly setProjectOptions: (projectId: string, options: ProjectOptions) => Promise<void>
}

type MachineSettings = Pick<CodevisorDatabaseService, "getMachineSetting" | "setMachineSetting">

const recordsKey = "ephemeral-machines"
const decodeRecords = Schema.decodeUnknownSync(
  Schema.fromJsonString(Schema.Array(EphemeralMachine))
)
const decodeOptions = Schema.decodeUnknownSync(Schema.fromJsonString(EphemeralProjectOptions))

export const makeEphemeralRecordStore = (db: MachineSettings): EphemeralRecordStore => {
  let writes = Promise.resolve()
  const list = async (): Promise<ReadonlyArray<EphemeralMachine>> => {
    const stored = await run(db.getMachineSetting(recordsKey))
    return stored === undefined ? [] : decodeRecords(stored)
  }
  const update = (
    change: (records: ReadonlyArray<EphemeralMachine>) => ReadonlyArray<EphemeralMachine>
  ) => {
    writes = writes.then(async () => {
      await run(db.setMachineSetting(recordsKey, JSON.stringify(change(await list()))))
    })
    return writes
  }
  return {
    list,
    get: async (id) => (await list()).find((machine) => machine.id === id),
    put: (machine) =>
      update((records) => [...records.filter((record) => record.id !== machine.id), machine]),
    remove: (id) => update((records) => records.filter((record) => record.id !== id)),
    projectOptions: async (projectId) => {
      const stored = await run(db.getMachineSetting(optionsKey(projectId)))
      return stored === undefined ? {} : decodeOptions(stored)
    },
    setProjectOptions: async (projectId, options) => {
      await run(db.setMachineSetting(optionsKey(projectId), JSON.stringify(options)))
    }
  }
}

const optionsKey = (projectId: string): string => `ephemeral-project-options:${projectId}`
