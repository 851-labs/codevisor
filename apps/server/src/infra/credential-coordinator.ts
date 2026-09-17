import { createHash } from "node:crypto"
import { readFile } from "node:fs/promises"
import { join } from "node:path"

import {
  coordinateCredential,
  type CredentialCommand,
  type CredentialCoordinationResult,
  type CredentialRecord
} from "@codevisor/api"
import { atomicWriteJson, withFileLock, SharedCredentialError } from "@codevisor/harness-manager"

interface SavedCredential {
  cloud?: string
  account?: string
  binding?: string
  record?: CredentialRecord
}
interface CloudCredential {
  serverUrl?: string
  apiKey?: string
  deviceId?: string
}
const binding = (cloud: CloudCredential) =>
  createHash("sha256")
    .update(JSON.stringify([cloud.serverUrl, cloud.apiKey, cloud.deviceId]))
    .digest("hex")

/// Local-only accounts work without a cloud login. On first cloud connection,
/// their encrypted state is seeded once. Once a grant has entered the cloud,
/// disconnection must never fall back to an independent local refresher.
export const makeCredentialCoordinator = (options: {
  readonly dataDir: string
  readonly fetch?: typeof fetch
}) => {
  const request = options.fetch ?? fetch
  const pathFor = (id: string) => {
    if (!/^[a-zA-Z0-9_-]{16,100}$/.test(id)) throw new Error("Invalid credential id")
    return join(options.dataDir, "shared-credentials", `${id}.json`)
  }
  const readCloud = async (): Promise<CloudCredential> => {
    try {
      return JSON.parse(await readFile(join(options.dataDir, "cloud.json"), "utf8"))
    } catch (cause) {
      if ((cause as NodeJS.ErrnoException).code !== "ENOENT") throw cause
      return {}
    }
  }
  const command = async (
    id: string,
    body: CredentialCommand
  ): Promise<CredentialCoordinationResult> => {
    const path = pathFor(id)
    let result!: CredentialCoordinationResult
    await withFileLock(path, async () => {
      const stored = JSON.parse(await readFile(path, "utf8")) as SavedCredential
      const cloud = await readCloud()
      if (cloud.serverUrl && cloud.apiKey && cloud.deviceId) {
        const origin = cloud.serverUrl.replace(/\/+$/, "")
        if (stored.cloud !== undefined && stored.cloud !== origin)
          throw new SharedCredentialError("reauthenticate")
        let account = stored.account
        const send = async (payload: CredentialCommand): Promise<CredentialCoordinationResult> => {
          const response = await request(
            `${origin}/api/machine/credentials/${encodeURIComponent(id)}`,
            {
              method: "POST",
              headers: {
                "x-api-key": cloud.apiKey!,
                "content-type": "application/json",
                ...(account ? { "x-codevisor-account": account } : {})
              },
              body: JSON.stringify(payload),
              signal: AbortSignal.timeout(10_000),
              redirect: "error"
            }
          )
          if (response.status === 409) throw new SharedCredentialError("reauthenticate")
          if (!response.ok) throw new Error("Account sync is unavailable")
          const scope = response.headers.get("x-codevisor-account")
          if (!scope || (account !== undefined && account !== scope))
            throw new SharedCredentialError("reauthenticate")
          account = scope
          return (await response.json()) as CredentialCoordinationResult
        }
        // Check account identity before sending any credential mutation. An
        // API key can rotate, and the user can sign into a different account.
        if (account === undefined) await send({ action: "read" })
        if (stored.cloud === undefined && stored.record !== undefined) {
          if (stored.record.operation !== undefined)
            throw new Error("Account refresh must finish before connecting")
          const seeded = await send(
            stored.record.revoked
              ? { action: "revoke" }
              : { action: "seed", sealed: stored.record.sealed }
          )
          // Persist the authority transition before allowing any provider I/O.
          await atomicWriteJson(path, {
            cloud: origin,
            account,
            binding: binding(cloud),
            ...(seeded.credential === undefined ? {} : { record: seeded.credential })
          })
        } else if (stored.cloud === undefined) {
          await atomicWriteJson(path, { cloud: origin, account, binding: binding(cloud) })
        }
        result = await send(body)
        await atomicWriteJson(path, {
          cloud: origin,
          account,
          binding: binding(cloud),
          ...(result.credential === undefined ? {} : { record: result.credential })
        })
        return
      }
      if (stored.cloud !== undefined) throw new Error("Connect to sync this account")
      const next = coordinateCredential(stored.record, body, "local", Date.now())
      await atomicWriteJson(path, next.record === undefined ? {} : { record: next.record })
      result = next.result
    })
    return result
  }
  return Object.assign(command, {
    cached: async (id: string) => {
      const stored = JSON.parse(await readFile(pathFor(id), "utf8")) as SavedCredential
      if (stored.cloud !== undefined && stored.binding !== binding(await readCloud()))
        return undefined
      return stored.record
    }
  })
}
