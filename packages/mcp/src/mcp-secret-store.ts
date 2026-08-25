import type {
  OAuthClientInformationMixed,
  OAuthTokens
} from "@modelcontextprotocol/sdk/shared/auth.js"
import type { OAuthDiscoveryState } from "@modelcontextprotocol/sdk/client/auth.js"
import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto"
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"

export interface StoredOAuth {
  readonly clientInformation?: OAuthClientInformationMixed | undefined
  readonly tokens?: OAuthTokens | undefined
  readonly tokensSavedAt?: number | undefined
  /// The server id of the machine that owns REFRESHING these tokens.
  /// Exactly one machine rotates; everyone else mirrors via config sync.
  /// Absent (legacy) means this machine owns them.
  readonly refreshOwner?: string | undefined
  readonly codeVerifier?: string | undefined
  readonly discoveryState?: OAuthDiscoveryState | undefined
  readonly state?: string | undefined
  readonly redirectUrl?: string | undefined
  readonly configuredClientId?: string | undefined
  readonly configuredClientSecret?: string | undefined
}

export interface StoredSecrets {
  readonly env?: Record<string, string> | undefined
  readonly headers?: Record<string, string> | undefined
  readonly bearerToken?: string | undefined
  readonly oauth?: StoredOAuth | undefined
}

export const loadEncryptionKey = (dataDir: string): Buffer => {
  const configured = process.env.CODEVISOR_MCP_SECRET_KEY ?? process.env.HERDMAN_MCP_SECRET_KEY
  if (configured !== undefined) {
    const key = Buffer.from(configured, "base64")
    if (key.length !== 32) throw new Error("CODEVISOR_MCP_SECRET_KEY must be 32 bytes in base64")
    return key
  }
  mkdirSync(dataDir, { recursive: true, mode: 0o700 })
  const path = join(dataDir, "mcp-secret-key")
  if (!existsSync(path)) {
    writeFileSync(path, randomBytes(32), { mode: 0o600 })
  }
  chmodSync(path, 0o600)
  const key = readFileSync(path)
  if (key.length !== 32) throw new Error(`Invalid MCP secret key at ${path}`)
  return key
}

export const encryptSecrets = (key: Buffer, value: StoredSecrets): string => {
  const iv = randomBytes(12)
  const cipher = createCipheriv("aes-256-gcm", key, iv)
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(value), "utf8"), cipher.final()])
  return Buffer.concat([iv, cipher.getAuthTag(), ciphertext]).toString("base64")
}

export const decryptSecrets = (key: Buffer, value: string | undefined): StoredSecrets => {
  if (value === undefined) return {}
  const encoded = Buffer.from(value, "base64")
  if (encoded.length < 29) throw new Error("Invalid encrypted MCP credentials")
  const decipher = createDecipheriv("aes-256-gcm", key, encoded.subarray(0, 12))
  decipher.setAuthTag(encoded.subarray(12, 28))
  return JSON.parse(
    Buffer.concat([decipher.update(encoded.subarray(28)), decipher.final()]).toString("utf8")
  ) as StoredSecrets
}
