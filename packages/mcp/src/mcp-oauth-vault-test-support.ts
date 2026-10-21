import { randomUUID } from "node:crypto"

import type { CodevisorDatabaseService } from "@codevisor/db"
import { Effect } from "effect"
import { vi } from "vitest"

import type { McpCredentialReference, McpOAuthVault, McpTokenBundle } from "./mcp-oauth-grant.js"
import { encryptSecrets, loadEncryptionKey, type StoredOAuth } from "./mcp-secret-store.js"

export const memoryOAuthVault = (rotate?: (bundle: McpTokenBundle) => McpTokenBundle) => {
  const bundles = new Map<string, McpTokenBundle>()
  const revoked = new Set<string>()
  const vault = {
    create: vi.fn(async (bundle: McpTokenBundle): Promise<McpCredentialReference> => {
      const reference = { id: randomUUID(), key: randomUUID() }
      bundles.set(reference.id, bundle)
      return reference
    }),
    token: vi.fn(async (reference: McpCredentialReference, rejectedAccessToken?: string) => {
      const bundle = bundles.get(reference.id)
      if (bundle === undefined || revoked.has(reference.id)) {
        throw Object.assign(new Error("Signed out"), { reason: "revoked" })
      }
      if (bundle.accessToken !== rejectedAccessToken || rotate === undefined) return bundle
      const next = rotate(bundle)
      bundles.set(reference.id, next)
      return next
    }),
    revoke: vi.fn(async (reference: McpCredentialReference) => {
      revoked.add(reference.id)
    })
  } satisfies McpOAuthVault
  return {
    vault,
    bundles,
    seed: (bundle: McpTokenBundle): McpCredentialReference => {
      const reference = { id: randomUUID(), key: randomUUID() }
      bundles.set(reference.id, bundle)
      return reference
    }
  }
}

export const bundleWithAccess = (accessToken: string): McpTokenBundle => ({
  harnessId: "mcp",
  subject: "https://tracker.example/mcp",
  accessToken,
  refreshToken: `refresh-${accessToken}`,
  expiresAt: Number.MAX_SAFE_INTEGER,
  ownership: "managed",
  credential: {
    authorizationServerUrl: "https://auth.tracker.example",
    client: { client_id: "client" }
  }
})

export const seedLegacyOAuth = async (
  db: CodevisorDatabaseService,
  directory: string,
  id: string,
  oauth: StoredOAuth
): Promise<void> => {
  const stored = await Effect.runPromise(db.getMcpServer(id))
  if (stored === undefined) throw new Error(`Missing ${id}`)
  await Effect.runPromise(
    db.saveMcpServer({
      id: stored.id,
      name: stored.name,
      transport: stored.transport,
      ...(stored.url === undefined ? {} : { url: stored.url }),
      enabled: stored.enabled,
      authType: stored.authType,
      connectionState: stored.connectionState,
      toolCount: stored.toolCount,
      secretCipher: encryptSecrets(loadEncryptionKey(directory), { oauth })
    })
  )
}
