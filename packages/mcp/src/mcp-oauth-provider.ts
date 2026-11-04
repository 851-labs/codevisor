import type { McpServerRecord } from "@codevisor/db"
import type { OAuthClientProvider } from "@modelcontextprotocol/sdk/client/auth.js"
import type {
  OAuthClientInformationMixed,
  OAuthClientMetadata,
  OAuthTokens
} from "@modelcontextprotocol/sdk/shared/auth.js"

import type { StoredOAuth, StoredSecrets } from "./mcp-secret-store.js"

export const configuredClient = (
  oauth: StoredOAuth | undefined
): OAuthClientInformationMixed | undefined =>
  oauth?.configuredClientId === undefined
    ? undefined
    : {
        client_id: oauth.configuredClientId,
        ...(oauth.configuredClientSecret === undefined
          ? {}
          : { client_secret: oauth.configuredClientSecret })
      }

export const registeredClient = (
  oauth: StoredOAuth | undefined,
  redirectUrl: string
): OAuthClientInformationMixed | undefined =>
  configuredClient(oauth) ?? oauth?.registrations?.[redirectUrl]

export interface OAuthProviderDeps {
  readonly callbackUrl: () => string
  readonly record: (id: string) => Promise<McpServerRecord>
  readonly replaceSecrets: (
    id: string,
    mutate: (current: StoredSecrets) => StoredSecrets
  ) => Promise<McpServerRecord>
  readonly secrets: (server: McpServerRecord) => StoredSecrets
  readonly saveTokens: (serverId: string, redirectUrl: string, tokens: OAuthTokens) => Promise<void>
}

export const makeOAuthProvider =
  (deps: OAuthProviderDeps) =>
  (
    serverId: string,
    savedRedirectUrl?: string
  ): OAuthClientProvider & { authorizationUrl?: URL } => {
    const redirectUrl = savedRedirectUrl ?? deps.callbackUrl()
    const provider: OAuthClientProvider & { authorizationUrl?: URL } = {
      redirectUrl,
      get clientMetadata(): OAuthClientMetadata {
        return {
          client_name: "Codevisor",
          redirect_uris: [redirectUrl],
          grant_types: ["authorization_code", "refresh_token"],
          response_types: ["code"],
          token_endpoint_auth_method: "none",
          scope: undefined
        }
      },
      state: async () => deps.secrets(await deps.record(serverId)).oauth?.state ?? "",
      clientInformation: async () =>
        registeredClient(deps.secrets(await deps.record(serverId)).oauth, redirectUrl),
      saveClientInformation: async (clientInformation) => {
        await deps.replaceSecrets(serverId, (value) => ({
          ...value,
          oauth: {
            ...value.oauth,
            registrations: { ...value.oauth?.registrations, [redirectUrl]: clientInformation }
          }
        }))
      },
      tokens: async () => undefined,
      saveTokens: (tokens) => deps.saveTokens(serverId, redirectUrl, tokens),
      redirectToAuthorization: (authorizationUrl) => {
        provider.authorizationUrl = authorizationUrl
      },
      saveCodeVerifier: async (codeVerifier) => {
        await deps.replaceSecrets(serverId, (value) => ({
          ...value,
          oauth: { ...value.oauth, codeVerifier }
        }))
      },
      codeVerifier: async () => {
        const value = deps.secrets(await deps.record(serverId)).oauth?.codeVerifier
        if (value === undefined) throw new Error("OAuth code verifier is missing")
        return value
      },
      saveDiscoveryState: async (discoveryState) => {
        await deps.replaceSecrets(serverId, (value) => ({
          ...value,
          oauth: { ...value.oauth, discoveryState }
        }))
      },
      discoveryState: async () => deps.secrets(await deps.record(serverId)).oauth?.discoveryState,
      invalidateCredentials: async (scope) => {
        if (scope === "tokens") return
        await deps.replaceSecrets(serverId, (value) => {
          if (scope === "verifier") {
            return { ...value, oauth: { ...value.oauth, codeVerifier: undefined } }
          }
          if (scope === "discovery") {
            return { ...value, oauth: { ...value.oauth, discoveryState: undefined } }
          }
          const { [redirectUrl]: _invalid, ...registrations } = value.oauth?.registrations ?? {}
          return { ...value, oauth: { ...value.oauth, registrations } }
        })
      }
    }
    return provider
  }
