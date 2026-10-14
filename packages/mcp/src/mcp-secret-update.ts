import type { UpdateMcpServerRequest } from "@codevisor/api"

import type { StoredOAuth, StoredSecrets } from "./mcp-secret-store.js"

const mergedSecretRecord = (
  current: Readonly<Record<string, string>> | undefined,
  updates: Readonly<Record<string, string>> | undefined,
  removals: ReadonlyArray<string> | undefined
): Record<string, string> | undefined => {
  const next = { ...current, ...updates }
  for (const name of removals ?? []) delete next[name]
  return Object.keys(next).length === 0 ? undefined : next
}

export const connectionSecretsSignature = (stored: StoredSecrets): string =>
  JSON.stringify({
    bearerToken:
      stored.bearerToken === undefined || stored.bearerToken === ""
        ? undefined
        : stored.bearerToken,
    headers: stored.headers === undefined ? undefined : Object.entries(stored.headers).toSorted(),
    env: stored.env === undefined ? undefined : Object.entries(stored.env).toSorted(),
    oauth:
      stored.oauth === undefined
        ? undefined
        : {
            configuredClientId: stored.oauth.configuredClientId,
            configuredClientSecret: stored.oauth.configuredClientSecret,
            tokens: stored.oauth.tokens
          }
  })

const updatedOAuth = (
  current: StoredSecrets,
  request: UpdateMcpServerRequest
): StoredOAuth | undefined =>
  request.oauthClientId === undefined && request.oauthClientSecret === undefined
    ? current.oauth
    : {
        ...current.oauth,
        ...(request.oauthClientId === undefined
          ? {}
          : { configuredClientId: request.oauthClientId }),
        ...(request.oauthClientSecret === undefined
          ? {}
          : { configuredClientSecret: request.oauthClientSecret })
      }

export const updatedSecrets = (
  current: StoredSecrets,
  request: UpdateMcpServerRequest
): StoredSecrets => {
  const updatedOauth = updatedOAuth(current, request)
  return {
    ...current,
    ...(request.env === undefined && request.removeEnv === undefined
      ? {}
      : { env: mergedSecretRecord(current.env, request.env, request.removeEnv) }),
    ...(request.headers === undefined && request.removeHeaders === undefined
      ? {}
      : {
          headers: mergedSecretRecord(current.headers, request.headers, request.removeHeaders)
        }),
    ...(request.bearerToken === undefined ? {} : { bearerToken: request.bearerToken }),
    ...(updatedOauth === undefined ? {} : { oauth: updatedOauth })
  }
}
