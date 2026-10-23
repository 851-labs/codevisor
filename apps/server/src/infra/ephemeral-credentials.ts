import type { CodevisorDatabaseService } from "@codevisor/db"
import type { EphemeralProviderId } from "@codevisor/ephemeral-machines"
import { decryptSecrets, encryptSecrets } from "@codevisor/mcp"

import { HttpFailure, run } from "../server-context.js"

export const EPHEMERAL_CREDENTIAL_KEYS: Readonly<
  Record<EphemeralProviderId, ReadonlyArray<string>>
> = {
  e2b: ["apiKey"],
  modal: ["tokenId", "tokenSecret"],
  tart: []
}

export type ProviderCredentials = Readonly<Record<string, string>>

export interface EphemeralCredentialStore {
  readonly isConfigured: (provider: EphemeralProviderId) => Promise<boolean>
  readonly save: (provider: EphemeralProviderId, values: ProviderCredentials) => Promise<void>
  readonly clear: (provider: EphemeralProviderId) => Promise<void>
  readonly read: (provider: EphemeralProviderId) => Promise<ProviderCredentials | undefined>
}

export const makeEphemeralCredentialStore = (
  db: Pick<CodevisorDatabaseService, "getMachineSetting" | "setMachineSetting">,
  secretKey: () => Buffer
): EphemeralCredentialStore => {
  const read = async (provider: EphemeralProviderId): Promise<ProviderCredentials | undefined> => {
    if (EPHEMERAL_CREDENTIAL_KEYS[provider].length === 0) return {}

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

const settingKey = (provider: EphemeralProviderId): string =>
  `ephemeral-provider-credentials:${provider}`

const completeCredentials = (
  provider: EphemeralProviderId,
  values: ProviderCredentials
): Record<string, string> => {
  const keys = EPHEMERAL_CREDENTIAL_KEYS[provider]
  if (keys.length === 0) throw new HttpFailure(400, `${provider} doesn't need credentials`)

  const trimmed = Object.fromEntries(keys.map((key) => [key, values[key]?.trim() ?? ""]))
  const missing = keys.filter((key) => trimmed[key] === "")
  if (missing.length > 0) throw new HttpFailure(400, `Missing ${missing.join(", ")}`)

  return trimmed
}
