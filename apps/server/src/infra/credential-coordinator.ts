import { createHash } from "node:crypto"
import { readFile } from "node:fs/promises"
import { join } from "node:path"

import {
  coordinateCredential,
  type CredentialCommand,
  type CredentialCoordinationResult
} from "@codevisor/api"
import { atomicWriteJson, withFileLock, SharedCredentialError } from "@codevisor/harness-manager"
import { Schema } from "effect"

import { errorCode } from "../unknown-values.js"

const CoordinatedCredential = Schema.Struct({
  generation: Schema.Number,
  sealed: Schema.String,
  revoked: Schema.Boolean
})

const CoordinationResult = Schema.Struct({
  status: Schema.Literals(["ready", "acquired", "busy", "uncertain", "missing", "revoked"]),
  credential: Schema.optionalKey(CoordinatedCredential)
})

const SavedCredential = Schema.Struct({
  cloud: Schema.optionalKey(Schema.String),
  account: Schema.optionalKey(Schema.String),
  binding: Schema.optionalKey(Schema.String),
  record: Schema.optionalKey(
    Schema.Struct({
      ...CoordinatedCredential.fields,
      operation: Schema.optionalKey(
        Schema.Struct({
          id: Schema.String,
          owner: Schema.String,
          deadline: Schema.Number,
          started: Schema.Boolean
        })
      ),
      committedOperation: Schema.optionalKey(Schema.String)
    })
  )
})

const readSaved = async (path: string) =>
  Schema.decodeUnknownSync(SavedCredential)(JSON.parse(await readFile(path, "utf8")))
interface CloudCredential {
  serverUrl?: string
  apiKey?: string
  deviceId?: string
}
const binding = (cloud: CloudCredential) =>
  createHash("sha256")
    .update(JSON.stringify([cloud.serverUrl, cloud.apiKey, cloud.deviceId]))
    .digest("hex")

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
      if (errorCode(cause) !== "ENOENT") throw cause
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
      const stored = await readSaved(path)
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
          return Schema.decodeUnknownSync(CoordinationResult)(await response.json())
        }
        if (account === undefined) await send({ action: "read" })
        if (stored.cloud === undefined && stored.record !== undefined) {
          if (stored.record.operation !== undefined)
            throw new Error("Account refresh must finish before connecting")
          const seeded = await send(
            stored.record.revoked
              ? { action: "revoke" }
              : { action: "seed", sealed: stored.record.sealed }
          )
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
      const stored = await readSaved(pathFor(id))
      if (stored.cloud !== undefined && stored.binding !== binding(await readCloud()))
        return undefined
      return stored.record
    }
  })
}
