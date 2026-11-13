import { isoTimestamp } from "@codevisor/api"
import type Database from "better-sqlite3"

import { instanceMetaSql, readInstanceMeta } from "./common-rows.js"
import { attempt } from "./errors.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"

export const FIRST_RUN_PROJECTS_SETTING = "first-run-projects"

export const FIRST_RUN_PROJECTS_PENDING = "pending"

export const ARCHIVE_RETENTION_SINCE_SETTING = "archive-retention-since"

export const makeMachineSettingsService = ({
  sqlite
}: ServiceContext): Pick<CodevisorDatabaseService, "getMachineSetting" | "setMachineSetting"> => ({
  getMachineSetting: (key) =>
    attempt("getMachineSetting", () => readInstanceMeta(sqlite, settingKey(key))),
  setMachineSetting: (key, value) =>
    attempt("setMachineSetting", () => {
      if (value === undefined) {
        sqlite.prepare(instanceMetaSql.delete).run(settingKey(key))
        return
      }
      sqlite.prepare(instanceMetaSql.upsert).run(settingKey(key), value)
    })
})

export const markFirstRunProjectsPending = (sqlite: Database.Database): void => {
  sqlite
    .prepare(instanceMetaSql.upsert)
    .run(settingKey(FIRST_RUN_PROJECTS_SETTING), FIRST_RUN_PROJECTS_PENDING)
}

export const startArchiveRetentionGrace = (sqlite: Database.Database): void => {
  sqlite
    .prepare(instanceMetaSql.upsert)
    .run(settingKey(ARCHIVE_RETENTION_SINCE_SETTING), isoTimestamp())
}

const settingKey = (key: string): string => `machine-setting:${key}`
