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

/// The coordinator is consulted at most this often for a credential that is
/// otherwise serving fine: reads inside the window come from memory.
const REVALIDATE_AFTER_MS = 5 * 60_000

export interface SharedCredentialVaultConfig {
  readonly coordinate: CredentialCoordinator
  readonly rotate: (bundle: SharedTokenBundle) => Promise<SharedTokenBundle>
  readonly now?: () => number
  readonly elapsed?: () => number
  readonly wait?: () => Promise<void>
  readonly readCached?: (id: string) => Promise<CoordinatedCredential | undefined>
  /// How long a credential fetched from the coordinator is served from memory
  /// before a read consults the coordinator again. Bounds how long a sign-out
  /// on another machine can go unnoticed here. 0 consults it on every read.
  readonly revalidateAfterMs?: number
  /// Durable local receipt lets a restarted process retry publication without
  /// ever retrying the provider exchange. Never log its encrypted contents.
  readonly receipt: {
    read(id: string): Promise<{ operationId: string; sealed: string } | undefined>
    write(id: string, value: { operationId: string; sealed: string }): Promise<void>
    remove(id: string): Promise<void>
  }
}

/// Access tokens closer to expiry than this are refreshed instead of served,
/// so a long request never starts on a token that dies underneath it.
const minimumValidityMs = (harnessId: SharedTokenBundle["harnessId"]): number =>
  ["pi", "opencode", "grok-build"].includes(harnessId) ? 6 * 60_000 : 60_000

/// Reads are local-first. The coordinator exists to elect a single refresher
/// across machines and to hold the sealed result; it is not the read path. A
/// credential fetched from it is served from memory until it nears expiry, a
/// provider rejects it, this process has an uncommitted refresh receipt, or
/// the revalidation window lapses. Cloud traffic is therefore proportional to
/// refreshes and windows, not to how often callers ask for a token.
export const makeSharedCredentialVault = (config: SharedCredentialVaultConfig) => {
  const now = config.now ?? Date.now
  const elapsed = config.elapsed ?? (() => performance.now())
  const wait = config.wait ?? (() => new Promise<void>((resolve) => setTimeout(resolve, 150)))
  const revalidateAfterMs = config.revalidateAfterMs ?? REVALIDATE_AFTER_MS
  const flights = new Map<string, Promise<SharedTokenBundle>>()
  /// Credentials as last confirmed by the coordinator, with the bundle already
  /// opened so the local path never decrypts per call.
  const cached = new Map<
    string,
    { credential: CoordinatedCredential; bundle: SharedTokenBundle; verifiedAt: number }
  >()
  /// Receipts this process wrote and has not yet committed. A pending receipt
  /// means the cached credential predates a refresh whose outcome the
  /// coordinator has not confirmed, so it must not be served locally.
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
  /// The bundle the coordinator last confirmed, while that confirmation is
  /// still inside the window and no refresh of ours awaits its commit.
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
    const held = local(reference, rejectedAccessToken)
    if (held !== undefined) return held
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
      // Discovery republishes on every sweep; a mirror the coordinator already
      // confirmed makes that sweep free.
      const confirmed = held(reference)
      if (confirmed !== undefined && !isNewer(confirmed)) return
      const state = await config.coordinate(reference.id, { action: "read" })
      if (state.status === "missing") {
        // The coordinator lost the grant (a cloud store reset, or a seed that
        // never landed) while the synced reference survived. Every read then
        // fails with "sign in again" even though the CLI login this mirrors is
        // live. The mirror has no refresh token to fork, so re-seed it under
        // the same reference. Seeding never overwrites a revoked record, so a
        // deliberate sign-out stays signed out.
        const seeded = await config.coordinate(reference.id, {
          action: "seed",
          sealed: sealSharedCredential(reference, bundle)
        })
        remember(reference, seeded.credential)
        return
      }
      const previous = remember(reference, state.credential)
      if (
        previous.ownership !== "external" ||
        previous.subject !== bundle.subject ||
        previous.organizationId !== bundle.organizationId ||
        previous.providerId !== bundle.providerId ||
        previous.harnessId !== bundle.harnessId
      )
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
    /// Drop held credentials so the next read consults the coordinator: a
    /// change from another machine (a sign-out) need not wait for the window.
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
