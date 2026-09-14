import { homedir } from "node:os"
import { join, resolve } from "node:path"

/// Canonical Codevisor directory layout, identical on every OS:
///   ~/.codevisor/data   – sqlite metadata + attachments and sidecar state
///   ~/.codevisor/server – standalone install runtime (managed by install.sh)
///   ~/.codevisor/logs   – server logs for non-service runs
///   ~/.codevisor/repos  – managed git clones (see @codevisor/db paths)
/// An identical layout on every machine is a prerequisite for moving sessions
/// between machines. Worktrees intentionally live at ~/codevisor instead (see
/// @codevisor/db paths.ts).
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

/// Old root systemd units pass the former default explicitly. Translate that
/// one known default on startup, including automatic updates that do not run
/// install.sh. Deliberate custom paths and macOS keep their existing behavior.
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

/// Database locations that install.sh provisions (user and root installs).
/// Servers started on one of these are eligible for the tmp-directory data
/// migration even when the path arrives via an explicit --db flag, because the
/// systemd units always pass --db.
export const canonicalDatabasePaths = (): ReadonlyArray<string> => [
  defaultDatabasePath(),
  "/var/lib/codevisor/data/codevisor-server.sqlite"
]
