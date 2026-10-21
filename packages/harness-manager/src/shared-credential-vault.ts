import { createCipheriv, createDecipheriv, randomBytes, randomUUID } from "node:crypto"

import type { CoordinatedCredential, CredentialCoordinationResult } from "@codevisor/api"

import { refreshFailedLine, refreshSucceededLine } from "./shared-credential-refresh-log.js"
import {
  OAuthRefreshUnavailable,
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
  readonly log?: (line: string) => void
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

const sameGrant = (held: SharedTokenBundle, bundle: SharedTokenBundle): boolean =>
  held.refreshToken === bundle.refreshToken && held.accessToken === bundle.accessToken

interface OwnedRecord {
  readonly credential: CoordinatedCredential
  readonly bundle: SharedTokenBundle
}

const ownRecord = (
  reference: SharedCredentialReference,
  state: CredentialCoordinationResult
): OwnedRecord | undefined => {
  if (state.status !== "ready") return undefined
  const credential = state.credential!
  try {
    return {
      credential,
      bundle: openSharedCredential(reference, credential.sealed)
    }
  } catch {
    return undefined
  }
}

const minimumValidityMs = (harnessId: SharedTokenBundle["harnessId"]): number =>
  ["pi", "opencode", "grok-build", "mcp"].includes(harnessId) ? 6 * 60_000 : 60_000

const OFFLINE_VALIDITY_MS = 30_000
const LEASE_WAIT_MS = 8_000

const cannotRefresh = (bundle: SharedTokenBundle): boolean =>
  bundle.ownership !== "managed" || !bundle.refreshToken

const throwIfLeaseLost = (state: CredentialCoordinationResult): void => {
  if (state.status === "uncertain") throw new SharedCredentialError("reauthenticate")
  if (state.status === "revoked") throw new SharedCredentialError("revoked")
}

const commitFailure = (committed: CredentialCoordinationResult): SharedCredentialError["reason"] =>
  committed.status === "revoked" ? "revoked" : "reauthenticate"

export const makeSharedCredentialVault = (config: SharedCredentialVaultConfig) => {
  const now = config.now ?? Date.now
  const elapsed = config.elapsed ?? (() => performance.now())
  const wait = config.wait ?? (() => new Promise<void>((resolve) => setTimeout(resolve, 150)))
  const revalidateAfterMs = config.revalidateAfterMs ?? REVALIDATE_AFTER_MS
  const log = config.log ?? (() => {})
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
  const rotate = async (reference: SharedCredentialReference, bundle: SharedTokenBundle) => {
    try {
      const next = await config.rotate(bundle)
      log(refreshSucceededLine(reference, bundle, next))
      return next
    } catch (cause) {
      log(refreshFailedLine(reference, bundle, cause))
      throw cause instanceof SharedCredentialError
        ? cause
        : new SharedCredentialError("reauthenticate")
    }
  }
  const commitUnderLease = async (
    reference: SharedCredentialReference,
    generation: number,
    bundle: SharedTokenBundle
  ): Promise<boolean> => {
    const operationId = randomUUID()
    const acquired = await config.coordinate(reference.id, {
      action: "acquire",
      generation,
      operationId
    })
    if (acquired.status !== "acquired") return false
    const started = await config.coordinate(reference.id, { action: "start", operationId })
    if (started.status !== "acquired") return false
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
    return true
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
  const coordinatorFor = (reference: SharedCredentialReference) => ({
    read: () => config.coordinate(reference.id, { action: "read" }),
    acquire: (generation: number, operationId: string) =>
      config.coordinate(reference.id, { action: "acquire", generation, operationId }),
    start: (operationId: string) =>
      config.coordinate(reference.id, { action: "start", operationId }),
    release: (operationId: string) =>
      config.coordinate(reference.id, { action: "release", operationId }),
    commit: (operationId: string, sealed: string) =>
      config.coordinate(reference.id, { action: "commit", operationId, sealed })
  })
  const outlastsOutage = (token: SharedTokenBundle, rejectedAccessToken: string | undefined) =>
    token.expiresAt > now() + OFFLINE_VALIDITY_MS && token.accessToken !== rejectedAccessToken
  const offlineCopy = (
    reference: SharedCredentialReference,
    previous: CoordinatedCredential | undefined,
    rejectedAccessToken: string | undefined
  ): SharedTokenBundle => {
    if (previous === undefined) throw new SharedCredentialError("offline")
    if (previous.revoked) throw new SharedCredentialError("revoked")

    const token = openSharedCredential(reference, previous.sealed)
    if (outlastsOutage(token, rejectedAccessToken)) return token
    throw new SharedCredentialError("offline")
  }
  const lastVerified = (reference: SharedCredentialReference) =>
    cached.get(reference.id)?.credential
  const read = async (
    reference: SharedCredentialReference,
    rejectedAccessToken?: string
  ): Promise<SharedTokenBundle> => {
    const fresh = local(reference, rejectedAccessToken)
    if (fresh !== undefined) return fresh

    const coordinator = coordinatorFor(reference)
    let state
    try {
      await recover(reference)
      state = await coordinator.read()
    } catch (cause) {
      if (cause instanceof SharedCredentialError) throw cause
      if (!config.readCached)
        return offlineCopy(reference, lastVerified(reference), rejectedAccessToken)
      const stored = await config.readCached(reference.id).catch(() => undefined)
      return offlineCopy(reference, stored, rejectedAccessToken)
    }

    const deadline = elapsed() + LEASE_WAIT_MS
    for (;;) {
      const bundle = remember(reference, state.credential)
      if (serves(bundle, rejectedAccessToken)) return bundle
      if (cannotRefresh(bundle)) throw new SharedCredentialError("reauthenticate")

      const operationId = randomUUID()
      state = await coordinator.acquire(state.credential!.generation, operationId)
      if (state.status === "ready") continue
      throwIfLeaseLost(state)
      if (state.status !== "acquired") {
        if (elapsed() >= deadline) throw new SharedCredentialError("busy")
        await wait()
        state = await coordinator.read()
        continue
      }

      const started = await coordinator.start(operationId)
      if (started.status !== "acquired") throw new SharedCredentialError("reauthenticate")

      let rotated: SharedTokenBundle
      try {
        rotated = await rotate(reference, bundle)
      } catch (cause) {
        if (cause instanceof OAuthRefreshUnavailable) await coordinator.release(operationId)
        throw cause
      }
      if (hasDifferentCredentialAccount(rotated, bundle)) {
        throw new SharedCredentialError("reauthenticate")
      }

      const sealed = sealSharedCredential(reference, rotated)
      await writeReceipt(reference.id, { operationId, sealed })
      const committed = await coordinator.commit(operationId, sealed)
      if (committed.status !== "ready") throw new SharedCredentialError(commitFailure(committed))

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
      await commitUnderLease(reference, state.credential!.generation, bundle)
    },
    claim: async (
      reference: SharedCredentialReference,
      bundle: SharedTokenBundle
    ): Promise<boolean> => {
      const seeded = await config.coordinate(reference.id, {
        action: "seed",
        sealed: sealSharedCredential(reference, bundle)
      })
      const owned = ownRecord(reference, seeded)
      if (owned === undefined) return false
      if (sameGrant(owned.bundle, bundle)) {
        remember(reference, owned.credential)
        return true
      }

      if (!(await commitUnderLease(reference, owned.credential.generation, bundle)))
        throw new SharedCredentialError("busy")
      return true
    },
    confirm: async (
      reference: SharedCredentialReference,
      bundle: SharedTokenBundle
    ): Promise<boolean> => {
      const owned = ownRecord(reference, await config.coordinate(reference.id, { action: "read" }))
      return owned !== undefined && sameGrant(owned.bundle, bundle)
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
