import { createCipheriv, createDecipheriv, randomBytes, randomUUID } from "node:crypto"
import type { CoordinatedCredential } from "@codevisor/api"
import {
  SharedCredentialError,
  type CredentialCoordinator,
  type SharedCredentialReference,
  type SharedTokenBundle
} from "./shared-credential-types.js"

export const sealSharedCredential = (
  reference: SharedCredentialReference,
  bundle: SharedTokenBundle
): string => {
  const nonce = randomBytes(12)
  const cipher = createCipheriv("aes-256-gcm", Buffer.from(reference.key, "base64url"), nonce)
  cipher.setAAD(Buffer.from(reference.id))
  const encrypted = Buffer.concat([cipher.update(JSON.stringify(bundle), "utf8"), cipher.final()])
  return Buffer.concat([nonce, cipher.getAuthTag(), encrypted]).toString("base64url")
}

export const openSharedCredential = (
  reference: SharedCredentialReference,
  sealed: string
): SharedTokenBundle => {
  const bytes = Buffer.from(sealed, "base64url")
  const cipher = createDecipheriv(
    "aes-256-gcm",
    Buffer.from(reference.key, "base64url"),
    bytes.subarray(0, 12)
  )
  cipher.setAuthTag(bytes.subarray(12, 28))
  cipher.setAAD(Buffer.from(reference.id))
  const bundle = JSON.parse(
    Buffer.concat([cipher.update(bytes.subarray(28)), cipher.final()]).toString("utf8")
  ) as SharedTokenBundle
  if (
    !["codex", "claude-code", "pi", "opencode", "grok-build"].includes(bundle.harnessId) ||
    typeof bundle.subject !== "string" ||
    typeof bundle.accessToken !== "string" ||
    !Number.isFinite(bundle.expiresAt) ||
    (bundle.ownership !== "managed" && bundle.ownership !== "external")
  )
    throw new Error("Invalid shared credential")
  return bundle
}

export interface SharedCredentialVaultConfig {
  readonly coordinate: CredentialCoordinator
  readonly rotate: (bundle: SharedTokenBundle) => Promise<SharedTokenBundle>
  readonly now?: () => number
  readonly elapsed?: () => number
  readonly wait?: () => Promise<void>
  readonly readCached?: (id: string) => Promise<CoordinatedCredential | undefined>
  /// Durable local receipt lets a restarted process retry publication without
  /// ever retrying the provider exchange. Never log its encrypted contents.
  readonly receipt: {
    read(id: string): Promise<{ operationId: string; sealed: string } | undefined>
    write(id: string, value: { operationId: string; sealed: string }): Promise<void>
    remove(id: string): Promise<void>
  }
}

export const makeSharedCredentialVault = (config: SharedCredentialVaultConfig) => {
  const now = config.now ?? Date.now
  const elapsed = config.elapsed ?? (() => performance.now())
  const wait = config.wait ?? (() => new Promise<void>((resolve) => setTimeout(resolve, 150)))
  const flights = new Map<string, Promise<SharedTokenBundle>>()
  const cached = new Map<string, CoordinatedCredential>()
  const remember = (
    reference: SharedCredentialReference,
    credential: CoordinatedCredential | undefined
  ) => {
    if (credential === undefined) throw new SharedCredentialError("reauthenticate")
    if (credential.revoked) {
      cached.delete(reference.id)
      throw new SharedCredentialError("revoked")
    }
    cached.set(reference.id, credential)
    return openSharedCredential(reference, credential.sealed)
  }
  const recover = async (reference: SharedCredentialReference) => {
    const receipt = await config.receipt.read(reference.id)
    if (receipt === undefined) return
    const committed = await config.coordinate(reference.id, { action: "commit", ...receipt })
    if (committed.status !== "ready" && committed.status !== "revoked")
      throw new SharedCredentialError("reauthenticate")
    await config.receipt.remove(reference.id)
    remember(reference, committed.credential)
  }
  const read = async (
    reference: SharedCredentialReference,
    rejectedAccessToken?: string
  ): Promise<SharedTokenBundle> => {
    let state
    try {
      await recover(reference)
      state = await config.coordinate(reference.id, { action: "read" })
    } catch (cause) {
      if (cause instanceof SharedCredentialError) throw cause
      const previous = config.readCached
        ? await config.readCached(reference.id).catch(() => undefined)
        : cached.get(reference.id)
      if (previous !== undefined) {
        if (previous.revoked) throw new SharedCredentialError("revoked")
        const token = openSharedCredential(reference, previous.sealed)
        if (token.expiresAt > now() + 30_000 && token.accessToken !== rejectedAccessToken)
          return token
      }
      throw new SharedCredentialError("offline")
    }
    const deadline = elapsed() + 8_000
    for (;;) {
      const bundle = remember(reference, state.credential)
      const minimumValidity = ["pi", "opencode", "grok-build"].includes(bundle.harnessId)
        ? 6 * 60_000
        : 60_000
      if (bundle.expiresAt > now() + minimumValidity && bundle.accessToken !== rejectedAccessToken)
        return bundle
      if (bundle.ownership !== "managed" || !bundle.refreshToken)
        throw new SharedCredentialError("reauthenticate")
      const operationId = randomUUID()
      state = await config.coordinate(reference.id, {
        action: "acquire",
        generation: state.credential!.generation,
        operationId
      })
      if (state.status === "ready") continue
      if (state.status === "uncertain") throw new SharedCredentialError("reauthenticate")
      if (state.status === "revoked") throw new SharedCredentialError("revoked")
      if (state.status !== "acquired") {
        if (elapsed() >= deadline) throw new SharedCredentialError("busy")
        await wait()
        state = await config.coordinate(reference.id, { action: "read" })
        continue
      }
      const started = await config.coordinate(reference.id, { action: "start", operationId })
      if (started.status !== "acquired") throw new SharedCredentialError("reauthenticate")
      // No retry or lock release after this point: a failed response can still
      // mean the provider consumed the refresh token.
      const rotated = await config.rotate(bundle).catch(() => {
        throw new SharedCredentialError("reauthenticate")
      })
      if (
        rotated.subject !== bundle.subject ||
        rotated.organizationId !== bundle.organizationId ||
        rotated.providerId !== bundle.providerId ||
        rotated.harnessId !== bundle.harnessId
      ) {
        throw new SharedCredentialError("reauthenticate")
      }
      const sealed = sealSharedCredential(reference, rotated)
      await config.receipt.write(reference.id, { operationId, sealed })
      const committed = await config.coordinate(reference.id, {
        action: "commit",
        operationId,
        sealed
      })
      if (committed.status !== "ready")
        throw new SharedCredentialError(
          committed.status === "revoked" ? "revoked" : "reauthenticate"
        )
      await config.receipt.remove(reference.id)
      return remember(reference, committed.credential)
    }
  }
  return {
    create: async (bundle: SharedTokenBundle): Promise<SharedCredentialReference> => {
      const reference = { id: randomUUID(), key: randomBytes(32).toString("base64url") }
      const seeded = await config.coordinate(reference.id, {
        action: "seed",
        sealed: sealSharedCredential(reference, bundle)
      })
      remember(reference, seeded.credential)
      return reference
    },
    token: async (
      reference: SharedCredentialReference,
      rejectedAccessToken?: string
    ): Promise<SharedTokenBundle> => {
      const existing = flights.get(reference.id)
      if (existing !== undefined) {
        const token = await existing
        if (token.accessToken !== rejectedAccessToken) return token
        return read(reference, rejectedAccessToken)
      }
      const pending = read(reference, rejectedAccessToken).finally(() =>
        flights.delete(reference.id)
      )
      flights.set(reference.id, pending)
      return pending
    },
    publishExternal: async (
      reference: SharedCredentialReference,
      bundle: SharedTokenBundle
    ): Promise<void> => {
      if (bundle.ownership !== "external" || bundle.refreshToken !== undefined)
        throw new Error("Invalid external credential")
      const state = await config.coordinate(reference.id, { action: "read" })
      const previous = remember(reference, state.credential)
      if (
        previous.ownership !== "external" ||
        previous.subject !== bundle.subject ||
        previous.organizationId !== bundle.organizationId ||
        previous.providerId !== bundle.providerId ||
        previous.harnessId !== bundle.harnessId
      )
        return
      if (previous.accessToken === bundle.accessToken || previous.expiresAt > bundle.expiresAt)
        return
      const operationId = randomUUID()
      const acquired = await config.coordinate(reference.id, {
        action: "acquire",
        generation: state.credential!.generation,
        operationId
      })
      if (acquired.status !== "acquired") return
      const started = await config.coordinate(reference.id, { action: "start", operationId })
      if (started.status !== "acquired") return
      const sealed = sealSharedCredential(reference, bundle)
      await config.receipt.write(reference.id, { operationId, sealed })
      const committed = await config.coordinate(reference.id, {
        action: "commit",
        operationId,
        sealed
      })
      if (committed.status !== "ready") throw new SharedCredentialError("offline")
      await config.receipt.remove(reference.id)
      remember(reference, committed.credential)
    },
    revoke: async (reference: SharedCredentialReference): Promise<void> => {
      const result = await config.coordinate(reference.id, { action: "revoke" })
      if (result.status !== "revoked") throw new SharedCredentialError("offline")
      cached.delete(reference.id)
      await config.receipt.remove(reference.id)
    }
  }
}

export type SharedCredentialVault = ReturnType<typeof makeSharedCredentialVault>
