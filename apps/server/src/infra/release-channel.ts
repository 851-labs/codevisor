import type { CodevisorDatabaseService } from "@codevisor/db"
import { channelFromSyncedValue, readMachineUpdateChannel } from "@codevisor/updater"
import type { ServerUpdateChannel } from "@codevisor/updater"
import { Effect } from "effect"

/// This machine's update channel, as the cloud hub needs it at every hello
/// (the hub turns the tunnel on only for Alpha devices while
/// `TUNNEL_ROLLOUT` is "alpha"). Same precedence as the self-updater: the
/// host app's channel file, then the config plane's synced
/// `settings/updateChannel`. The synced value is read asynchronously, so each
/// call returns the last value read and refreshes it for the next hello.
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

/// The config plane's synced `settings/updateChannel` value, if any.
export const syncedUpdateChannel = async (
  db: Pick<CodevisorDatabaseService, "getSyncEntries">
): Promise<unknown> =>
  (await Effect.runPromise(db.getSyncEntries("settings"))).find(
    (entry) => entry.key === "updateChannel" && entry.deleted !== true
  )?.value

/// releaseChannelReader over this server's data dir and synced settings.
export const machineReleaseChannel = (
  dataDir: string,
  db: Pick<CodevisorDatabaseService, "getSyncEntries">
): (() => ServerUpdateChannel | undefined) =>
  releaseChannelReader({ dataDir, syncedValue: () => syncedUpdateChannel(db) })
