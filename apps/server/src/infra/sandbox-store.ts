import {
  Sandbox,
  SandboxProjectOptions,
  type SandboxProjectOptions as ProjectOptions
} from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { Schema } from "effect"

import { run } from "../server-context.js"

export interface SandboxRecordStore {
  readonly list: () => Promise<ReadonlyArray<Sandbox>>
  readonly get: (id: string) => Promise<Sandbox | undefined>
  readonly put: (machine: Sandbox) => Promise<void>
  readonly remove: (id: string) => Promise<void>
  readonly projectOptions: (projectId: string) => Promise<ProjectOptions>
  readonly setProjectOptions: (projectId: string, options: ProjectOptions) => Promise<void>
}

type MachineSettings = Pick<CodevisorDatabaseService, "getMachineSetting" | "setMachineSetting">

const recordsKey = "ephemeral-machines"
const decodeRecords = Schema.decodeUnknownSync(Schema.fromJsonString(Schema.Array(Sandbox)))
const decodeOptions = Schema.decodeUnknownSync(Schema.fromJsonString(SandboxProjectOptions))

export const makeSandboxRecordStore = (db: MachineSettings): SandboxRecordStore => {
  let writes = Promise.resolve()
  const list = async (): Promise<ReadonlyArray<Sandbox>> => {
    const stored = await run(db.getMachineSetting(recordsKey))
    return stored === undefined ? [] : decodeRecords(stored)
  }
  const update = (change: (records: ReadonlyArray<Sandbox>) => ReadonlyArray<Sandbox>) => {
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
