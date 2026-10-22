import { readInstanceMeta } from "./common-rows.js"
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
        sqlite.prepare("delete from instance_meta where key = ?").run(settingKey(key))
        return
      }
      sqlite
        .prepare(
          "insert into instance_meta (key, value) values (?, ?) on conflict(key) do update set value = excluded.value"
        )
        .run(settingKey(key), value)
    })
})
