import { createHash } from "node:crypto"

import { run } from "../server-context.js"
import { connectionOf } from "./sandbox-profile-record.js"
import { sandboxRemote, type SandboxRemote } from "./sandbox-remote.js"
import { applyOnRemote, type OneWaySyncSource } from "./sandbox-sync.js"
import type { PlacedMachine } from "./sandbox-watch.js"
import type { SandboxDeps } from "./sandboxes.js"

export const CREDENTIAL_SYNC_NAMESPACES = [
  "harness-accounts",
  "harness-credentials",
  "harness-shared-accounts"
] as const

export interface SandboxCredentials {
  readonly version: () => Promise<string>
  readonly sent: (sandboxId: string, version: string) => void
  readonly refresh: (sandboxId: string, remote: SandboxRemote) => Promise<boolean>
  readonly resend: (sandboxId: string, remote: SandboxRemote) => Promise<boolean>
}

export const makeSandboxCredentials = (
  source: OneWaySyncSource,
  log: (line: string) => void
): SandboxCredentials => {
  const pushed = new Map<string, string>()
  const version = () => credentialVersion(source)
  const send = async (sandboxId: string, remote: SandboxRemote, current: string) => {
    await pushCredentials(source, remote, log)
    pushed.set(sandboxId, current)
    return true
  }

  return {
    version,
    sent: (sandboxId, current) => {
      pushed.set(sandboxId, current)
    },
    refresh: async (sandboxId, remote) => {
      const current = await version()
      if (pushed.get(sandboxId) === current) return false

      return send(sandboxId, remote, current)
    },
    resend: async (sandboxId, remote) => send(sandboxId, remote, await version())
  }
}

export const refreshCredentials = (deps: SandboxDeps, machine: PlacedMachine): Promise<void> =>
  pushTo(deps, machine, deps.credentials.refresh)

export const resendCredentials = (deps: SandboxDeps, machine: PlacedMachine): Promise<void> =>
  pushTo(deps, machine, deps.credentials.resend)

const pushTo = async (
  deps: SandboxDeps,
  machine: PlacedMachine,
  push: SandboxCredentials["refresh"]
): Promise<void> => {
  try {
    const pushed = await push(machine.id, await remoteOf(deps, machine))
    if (pushed) deps.log(`Sandbox ${machine.name} (${machine.id}): refreshed harness sign-ins`)
  } catch (cause) {
    deps.log(`Refreshing harness sign-ins on sandbox ${machine.name} failed: ${messageOf(cause)}`)
  }
}

const pushCredentials = async (
  source: OneWaySyncSource,
  remote: SandboxRemote,
  log: (line: string) => void
): Promise<void> => {
  for (const namespace of CREDENTIAL_SYNC_NAMESPACES) {
    const entries = await run(source.db.getSyncEntries(namespace))
    await remote.request("PUT", `/v1/sync/${namespace}`, { entries })
  }
  const failed = await applyOnRemote(remote, credentialApplyPaths)
  if (failed.length > 0) log(`Applying harness sign-ins on a sandbox failed: ${failed.join(", ")}`)
}

const credentialVersion = async (source: OneWaySyncSource): Promise<string> => {
  const hash = createHash("sha256")
  for (const namespace of CREDENTIAL_SYNC_NAMESPACES) {
    for (const entry of await run(source.db.getSyncEntries(namespace))) {
      hash.update(JSON.stringify([namespace, entry.key, entry.timestamp, entry.deleted === true]))
    }
  }
  return hash.digest("hex")
}

const remoteOf = async (deps: SandboxDeps, machine: PlacedMachine): Promise<SandboxRemote> =>
  sandboxRemote(await deps.connections.connect(connectionOf(machine)), machine.providerMachineId)

const messageOf = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

const credentialApplyPaths = ["/v1/sync/credentials/reconcile", "/v1/sync/accounts/publish"]
