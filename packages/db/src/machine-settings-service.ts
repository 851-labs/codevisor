import { instanceMetaSql, readInstanceMeta } from "./common-rows.js"
import { attempt } from "./errors.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"

const settingKey = (key: string): string => `machine-setting:${key}`

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
