import { existsSync, readFileSync } from "node:fs"
import { join } from "node:path"
import type { ServerUpdateChannel } from "./release-source.js"

/// Files the host macOS app maintains next to an app-hosted server's
/// database (~/.codevisor/data). The app writes them; the server only reads.
///
/// - The CHANNEL file makes the machine that will actually install the
///   update the authority on which release feed it follows: Sparkle on an
///   app-hosted Mac always installs from that machine's own channel
///   preference, so a remote client's requested channel must not decide the
///   check either — otherwise the check and the install can disagree and an
///   "update" never converges.
/// - The STATUS file carries the unattended Sparkle session's outcome back
///   to the server, so a remote client polling /v1/update can see "failed:
///   <why>" instead of timing out against a machine that silently gave up.
export const APP_UPDATE_CHANNEL_FILE = "app-update-channel"
export const APP_UPDATE_STATUS_FILE = "app-update-status.json"

/// A failed status older than this is stale — most likely left over from an
/// interrupted session on a machine that has since moved on — and is not
/// worth surfacing against a fresh update attempt.
export const APP_UPDATE_STATUS_TTL_MS = 30 * 60 * 1000

/// The host app's report of its unattended update session, mirrored into
/// `UpdateInfo.lastApply` by app-hosted servers.
export type AppUpdateApplyState = {
  readonly state: "installing" | "failed"
  readonly message?: string | undefined
  readonly targetVersion?: string | undefined
  readonly at: string
}

/// Parses a config-plane `settings/updateChannel` value (@codevisor/sync)
/// into a channel. Standalone servers follow their synced replica the way
/// app-hosted Macs follow their channel file — the fleet's one preference
/// reaches every machine either way. Unknown values are ignored rather
/// than coerced: a malformed replica must not silently move a machine
/// between channels.
export const channelFromSyncedValue = (value: unknown): ServerUpdateChannel | undefined =>
  value === "alpha" || value === "stable" ? value : undefined

/// Reads the machine's own update channel, written by the host macOS app
/// whenever its Alpha-updates preference changes. Undefined when the file is
/// missing or unreadable (standalone servers, or an app predating the file);
/// unknown contents fall back to stable, mirroring the server's lenient
/// channel query parsing.
export const readMachineUpdateChannel = (dataDir: string): ServerUpdateChannel | undefined => {
  const path = join(dataDir, APP_UPDATE_CHANNEL_FILE)
  try {
    if (!existsSync(path)) return undefined
    const value = readFileSync(path, "utf8").trim()
    if (value.length === 0) return undefined
    return value === "alpha" ? "alpha" : "stable"
  } catch {
    return undefined
  }
}

/// Reads the host app's unattended-apply status report. Returns undefined
/// when there is nothing (fresh) to report: no file, malformed contents, or
/// a report older than the TTL.
export const readAppUpdateApplyState = (
  dataDir: string,
  now: () => number = Date.now
): AppUpdateApplyState | undefined => {
  const path = join(dataDir, APP_UPDATE_STATUS_FILE)
  let parsed: unknown
  try {
    if (!existsSync(path)) return undefined
    parsed = JSON.parse(readFileSync(path, "utf8"))
  } catch {
    return undefined
  }
  if (typeof parsed !== "object" || parsed === null) return undefined
  const value = parsed as {
    readonly state?: unknown
    readonly message?: unknown
    readonly targetVersion?: unknown
    readonly at?: unknown
  }
  if (value.state !== "installing" && value.state !== "failed") return undefined
  if (typeof value.at !== "string") return undefined
  const reportedAt = Date.parse(value.at)
  if (!Number.isFinite(reportedAt) || now() - reportedAt > APP_UPDATE_STATUS_TTL_MS) {
    return undefined
  }
  return {
    state: value.state,
    message: typeof value.message === "string" ? value.message : undefined,
    targetVersion: typeof value.targetVersion === "string" ? value.targetVersion : undefined,
    at: value.at
  }
}
