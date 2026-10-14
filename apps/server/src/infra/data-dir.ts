import { homedir } from "node:os"
import { join, resolve } from "node:path"

export const codevisorRoot = (): string => join(homedir(), ".codevisor")

export const resolveDataDir = (): string =>
  process.env["CODEVISOR_DATA_DIR"] ?? join(codevisorRoot(), "data")

export const resolveLogsDir = (): string =>
  process.env["CODEVISOR_LOGS_DIR"] ?? join(codevisorRoot(), "logs")

export const defaultDatabasePath = (): string => join(resolveDataDir(), "codevisor-server.sqlite")

export const LEGACY_LINUX_DATA_DIR = "/var/lib/codevisor/data"

export interface ServerDataLayout {
  readonly databasePath: string
  readonly legacyDataDirectory?: string
}

export const resolveServerDataLayout = (
  requestedDatabasePath?: string,
  context = {
    platform: process.platform as string,
    uid: process.getuid?.(),
    home: homedir(),
    dataDirectory: process.env.CODEVISOR_DATA_DIR
  }
): ServerDataLayout => {
  const canonical = join(context.home, ".codevisor", "data", "codevisor-server.sqlite")
  const requested = resolve(
    requestedDatabasePath ??
      join(
        context.dataDirectory ?? join(context.home, ".codevisor", "data"),
        "codevisor-server.sqlite"
      )
  )
  if (
    context.platform === "linux" &&
    context.uid === 0 &&
    context.dataDirectory === undefined &&
    (requested === canonical ||
      requested === join(LEGACY_LINUX_DATA_DIR, "codevisor-server.sqlite"))
  ) {
    return { databasePath: canonical, legacyDataDirectory: LEGACY_LINUX_DATA_DIR }
  }
  return { databasePath: requested }
}

export const canonicalDatabasePaths = (): ReadonlyArray<string> => [
  defaultDatabasePath(),
  "/var/lib/codevisor/data/codevisor-server.sqlite"
]
