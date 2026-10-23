import type { CodevisorDatabaseService } from "@codevisor/db"
import type { BlobStore } from "@codevisor/sync"

import { run } from "../server-context.js"
import type { EphemeralRemote } from "./ephemeral-remote.js"

export const ONE_WAY_SYNC_NAMESPACES = [
  "settings",
  "codevisor-skills",
  "mcps",
  "harness-accounts",
  "harnesses",
  "plugins",
  "mcp-readiness",
  "mcp-overlays",
  "harness-credentials",
  "harness-shared-accounts",
  "harness-readiness",
  "plugin-readiness",
  "client-preferences"
] as const

const applyPaths = [
  "/v1/sync/mcps/reconcile",
  "/v1/sync/harnesses/reconcile",
  "/v1/sync/plugins/reconcile",
  "/v1/sync/credentials/reconcile",
  "/v1/sync/accounts/publish"
]

export interface OneWaySyncSource {
  readonly db: Pick<CodevisorDatabaseService, "getSyncEntries">
  readonly blobs?: Pick<BlobStore, "has" | "read">
}

export interface OneWaySyncReport {
  readonly entries: number
  readonly skillBlobs: number
  readonly failedSteps: ReadonlyArray<string>
}

export const pushOneWaySync = async (
  source: OneWaySyncSource,
  remote: EphemeralRemote
): Promise<OneWaySyncReport> => {
  const entries = await pushNamespaces(source, remote)
  const failedSteps = await applyOnRemote(remote)
  const skillBlobs = await pushSkills(source, remote)
  return { entries, skillBlobs, failedSteps }
}

const pushNamespaces = async (
  source: OneWaySyncSource,
  remote: EphemeralRemote
): Promise<number> => {
  let pushed = 0
  for (const namespace of ONE_WAY_SYNC_NAMESPACES) {
    const entries = await run(source.db.getSyncEntries(namespace))
    await remote.request("PUT", `/v1/sync/${namespace}`, { entries })
    pushed += entries.length
  }
  return pushed
}

const applyOnRemote = async (remote: EphemeralRemote): Promise<ReadonlyArray<string>> => {
  const failed: string[] = []
  for (const path of applyPaths) {
    await remote.request("POST", path).catch(() => failed.push(path))
  }
  return failed
}

const pushSkills = async (source: OneWaySyncSource, remote: EphemeralRemote): Promise<number> => {
  const hashes = missingBlobHashes(await remote.request("POST", "/v1/sync/skills/reconcile"))
  let uploaded = 0
  for (const hash of hashes) {
    if (source.blobs?.has(hash) !== true) continue
    await remote.putBytes(`/v1/sync/blobs/${hash}`, await source.blobs.read(hash))
    uploaded += 1
  }
  if (uploaded > 0) await remote.request("POST", "/v1/sync/skills/reconcile")
  return uploaded
}

const missingBlobHashes = (status: unknown): ReadonlyArray<string> => {
  if (!isRecord(status) || !Array.isArray(status.missingBlobs)) return []
  return status.missingBlobs.flatMap((blob: unknown) =>
    isRecord(blob) && typeof blob.hash === "string" ? [blob.hash] : []
  )
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null
