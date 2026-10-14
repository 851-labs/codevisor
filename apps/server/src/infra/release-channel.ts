import type { CodevisorDatabaseService } from "@codevisor/db"
import { channelFromSyncedValue, readMachineUpdateChannel } from "@codevisor/updater"
import type { ServerUpdateChannel } from "@codevisor/updater"
import { Effect } from "effect"

export const releaseChannelReader = (options: {
  readonly dataDir: string
  readonly syncedValue: () => Promise<unknown>
}): (() => ServerUpdateChannel | undefined) => {
  let synced: ServerUpdateChannel | undefined
  const refresh = (): void => {
    options.syncedValue().then(
      (value) => {
        synced = channelFromSyncedValue(value)
      },
      () => undefined
    )
  }
  refresh()
  return () => {
    refresh()
    return readMachineUpdateChannel(options.dataDir) ?? synced
  }
}

export const syncedUpdateChannel = async (
  db: Pick<CodevisorDatabaseService, "getSyncEntries">
): Promise<unknown> =>
  (await Effect.runPromise(db.getSyncEntries("settings"))).find(
    (entry) => entry.key === "updateChannel" && entry.deleted !== true
  )?.value

export const machineReleaseChannel = (
  dataDir: string,
  db: Pick<CodevisorDatabaseService, "getSyncEntries">,
  env: Readonly<Record<string, string | undefined>>
): (() => ServerUpdateChannel | undefined) =>
  env.CODEVISOR_DEV_INSTANCE_ID === undefined
    ? releaseChannelReader({ dataDir, syncedValue: () => syncedUpdateChannel(db) })
    : () => "alpha"
