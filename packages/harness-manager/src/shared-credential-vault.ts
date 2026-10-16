import { createCipheriv, createDecipheriv, randomBytes, randomUUID } from "node:crypto"

import type { CoordinatedCredential } from "@codevisor/api"

import {
  SharedCredentialError,
  isSharedTokenBundle,
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
  const bundle: unknown = JSON.parse(
    Buffer.concat([cipher.update(bytes.subarray(28)), cipher.final()]).toString("utf8")
  )
  if (!isSharedTokenBundle(bundle)) throw new Error("Invalid shared credential")
  return bundle
}

const REVALIDATE_AFTER_MS = 5 * 60_000

export interface SharedCredentialVaultConfig {
  readonly coordinate: CredentialCoordinator
  readonly rotate: (bundle: SharedTokenBundle) => Promise<SharedTokenBundle>
  readonly now?: () => number
  readonly elapsed?: () => number
  readonly wait?: () => Promise<void>
  readonly readCached?: (id: string) => Promise<CoordinatedCredential | undefined>
  readonly revalidateAfterMs?: number
  readonly receipt: {
    read(id: string): Promise<{ operationId: string; sealed: string } | undefined>
    write(id: string, value: { operationId: string; sealed: string }): Promise<void>
    remove(id: string): Promise<void>
  }
}

const hasDifferentCredentialAccount = (
  candidate: SharedTokenBundle,
  previous: SharedTokenBundle
): boolean =>
  candidate.subject !== previous.subject ||
  candidate.organizationId !== previous.organizationId ||
  candidate.providerId !== previous.providerId ||
  candidate.harnessId !== previous.harnessId

const minimumValidityMs = (harnessId: SharedTokenBundle["harnessId"]): number =>
  ["pi", "opencode", "grok-build"].includes(harnessId) ? 6 * 60_000 : 60_000

export const makeSharedCredentialVault = (config: SharedCredentialVaultConfig) => {
  const now = config.now ?? Date.now
  const elapsed = config.elapsed ?? (() => performance.now())
  const wait = config.wait ?? (() => new Promise<void>((resolve) => setTimeout(resolve, 150)))
  const revalidateAfterMs = config.revalidateAfterMs ?? REVALIDATE_AFTER_MS
  const flights = new Map<string, Promise<SharedTokenBundle>>()
  const cached = new Map<
    string,
    { credential: CoordinatedCredential; bundle: SharedTokenBundle; verifiedAt: number }
  >()
  const pendingReceipts = new Set<string>()
  const remember = (
    reference: SharedCredentialReference,
    credential: CoordinatedCredential | undefined
  ) => {
    if (credential === undefined) throw new SharedCredentialError("reauthenticate")
    if (credential.revoked) {
      cached.delete(reference.id)
      throw new SharedCredentialError("revoked")
    }
    const bundle = openSharedCredential(reference, credential.sealed)
    cached.set(reference.id, { credential, bundle, verifiedAt: now() })
    return bundle
  }
  const writeReceipt = async (id: string, value: { operationId: string; sealed: string }) => {
    pendingReceipts.add(id)
    await config.receipt.write(id, value)
  }
  const removeReceipt = async (id: string) => {
    await config.receipt.remove(id)
    pendingReceipts.delete(id)
  }
  const recover = async (reference: SharedCredentialReference) => {
    const receipt = await config.receipt.read(reference.id)
    if (receipt === undefined) {
      pendingReceipts.delete(reference.id)
      return
    }
    const committed = await config.coordinate(reference.id, { action: "commit", ...receipt })
    if (committed.status !== "ready" && committed.status !== "revoked")
      throw new SharedCredentialError("reauthenticate")
    await removeReceipt(reference.id)
    remember(reference, committed.credential)
  }
  const serves = (bundle: SharedTokenBundle, rejectedAccessToken: string | undefined) =>
    bundle.expiresAt > now() + minimumValidityMs(bundle.harnessId) &&
    bundle.accessToken !== rejectedAccessToken
  const held = (reference: SharedCredentialReference): SharedTokenBundle | undefined => {
    const entry = cached.get(reference.id)
    if (entry === undefined || pendingReceipts.has(reference.id)) return undefined
    return now() - entry.verifiedAt < revalidateAfterMs ? entry.bundle : undefined
  }
  const local = (
    reference: SharedCredentialReference,
    rejectedAccessToken: string | undefined
  ): SharedTokenBundle | undefined => {
    const bundle = held(reference)
    return bundle !== undefined && serves(bundle, rejectedAccessToken) ? bundle : undefined
  }
  const read = async (
    reference: SharedCredentialReference,
    rejectedAccessToken?: string
  ): Promise<SharedTokenBundle> => {
    const fresh = local(reference, rejectedAccessToken)
    if (fresh !== undefined) return fresh
    let state
    try {
      await recover(reference)
      state = await config.coordinate(reference.id, { action: "read" })
    } catch (cause) {
      if (cause instanceof SharedCredentialError) throw cause
      const previous = config.readCached
        ? await config.readCached(reference.id).catch(() => undefined)
        : cached.get(reference.id)?.credential
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
      if (serves(bundle, rejectedAccessToken)) return bundle
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
      const rotated = await config.rotate(bundle).catch(() => {
        throw new SharedCredentialError("reauthenticate")
      })
      if (hasDifferentCredentialAccount(rotated, bundle)) {
        throw new SharedCredentialError("reauthenticate")
      }
      const sealed = sealSharedCredential(reference, rotated)
      await writeReceipt(reference.id, { operationId, sealed })
      const committed = await config.coordinate(reference.id, {
        action: "commit",
        operationId,
        sealed
      })
      if (committed.status !== "ready")
        throw new SharedCredentialError(
          committed.status === "revoked" ? "revoked" : "reauthenticate"
        )
      await removeReceipt(reference.id)
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
      const isNewer = (previous: SharedTokenBundle) =>
        previous.accessToken !== bundle.accessToken && previous.expiresAt <= bundle.expiresAt
      const confirmed = held(reference)
      if (confirmed !== undefined && !isNewer(confirmed)) return
      const state = await config.coordinate(reference.id, { action: "read" })
      if (state.status === "missing") {
        const seeded = await config.coordinate(reference.id, {
          action: "seed",
          sealed: sealSharedCredential(reference, bundle)
        })
        remember(reference, seeded.credential)
        return
      }
      const previous = remember(reference, state.credential)
      if (previous.ownership !== "external" || hasDifferentCredentialAccount(previous, bundle))
        return
      if (!isNewer(previous)) return
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
      await writeReceipt(reference.id, { operationId, sealed })
      const committed = await config.coordinate(reference.id, {
        action: "commit",
        operationId,
        sealed
      })
      if (committed.status !== "ready") throw new SharedCredentialError("offline")
      await removeReceipt(reference.id)
      remember(reference, committed.credential)
    },
    invalidate: (): void => cached.clear(),
    revoke: async (reference: SharedCredentialReference): Promise<void> => {
      const result = await config.coordinate(reference.id, { action: "revoke" })
      if (result.status !== "revoked") throw new SharedCredentialError("offline")
      cached.delete(reference.id)
      await removeReceipt(reference.id)
    }
  }
}

export type SharedCredentialVault = ReturnType<typeof makeSharedCredentialVault>
