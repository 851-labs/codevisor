import { homedir } from "node:os"
import { join } from "node:path"

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

export const resolveLogsDir = (): string => join(codevisorRoot(), "logs")

export const defaultDatabasePath = (): string => join(resolveDataDir(), "codevisor-server.sqlite")

/// Database locations that install.sh provisions (user and root installs).
/// Servers started on one of these are eligible for the tmp-directory data
/// migration even when the path arrives via an explicit --db flag, because the
/// systemd units always pass --db.
export const canonicalDatabasePaths = (): ReadonlyArray<string> => [
  defaultDatabasePath(),
  "/var/lib/codevisor/data/codevisor-server.sqlite"
]
