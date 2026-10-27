import type { CodevisorDatabaseService } from "@codevisor/db"
import { decryptSecrets, encryptSecrets } from "@codevisor/mcp"
import type { SandboxProviderId } from "@codevisor/sandboxes"

import { HttpFailure, run } from "../server-context.js"

export const SANDBOX_CREDENTIAL_KEYS: Readonly<Record<SandboxProviderId, ReadonlyArray<string>>> = {
  e2b: ["apiKey"],
  modal: ["tokenId", "tokenSecret"],
  tart: []
}

export type ProviderCredentials = Readonly<Record<string, string>>

export interface SandboxCredentialStore {
  readonly isConfigured: (provider: SandboxProviderId) => Promise<boolean>
  readonly save: (provider: SandboxProviderId, values: ProviderCredentials) => Promise<void>
  readonly clear: (provider: SandboxProviderId) => Promise<void>
  readonly read: (provider: SandboxProviderId) => Promise<ProviderCredentials | undefined>
}

export const makeSandboxCredentialStore = (
  db: Pick<CodevisorDatabaseService, "getMachineSetting" | "setMachineSetting">,
  secretKey: () => Buffer
): SandboxCredentialStore => {
  const read = async (provider: SandboxProviderId): Promise<ProviderCredentials | undefined> => {
    if (SANDBOX_CREDENTIAL_KEYS[provider].length === 0) return {}

    const sealed = await run(db.getMachineSetting(settingKey(provider)))
    if (sealed === undefined) return undefined
    return decryptSecrets(secretKey(), sealed).env
  }
  return {
    read,
    isConfigured: async (provider) => (await read(provider)) !== undefined,
    save: async (provider, values) => {
      const complete = completeCredentials(provider, values)
      await run(
        db.setMachineSetting(settingKey(provider), encryptSecrets(secretKey(), { env: complete }))
      )
    },
    clear: async (provider) => {
      await run(db.setMachineSetting(settingKey(provider), undefined))
    }
  }
}

const settingKey = (provider: SandboxProviderId): string =>
  `ephemeral-provider-credentials:${provider}`

const completeCredentials = (
  provider: SandboxProviderId,
  values: ProviderCredentials
): Record<string, string> => {
  const keys = SANDBOX_CREDENTIAL_KEYS[provider]
  if (keys.length === 0) throw new HttpFailure(400, `${provider} doesn't need credentials`)

  const trimmed = Object.fromEntries(keys.map((key) => [key, values[key]?.trim() ?? ""]))
  const missing = keys.filter((key) => trimmed[key] === "")
  if (missing.length > 0) throw new HttpFailure(400, `Missing ${missing.join(", ")}`)

  return trimmed
}
