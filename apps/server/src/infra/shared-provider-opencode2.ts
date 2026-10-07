import { join } from "node:path"

import {
  makeOpenCode2Accounts,
  makeOpenCodeLocator,
  makeOpenCodeServerPool,
  makeOpenCodeVersionProbe,
  openCodeCredentialPluginFiles,
  OPENCODE_MANAGED_METHODS,
  SEEDED_CREDENTIAL_PREFIX,
  type SeededOpenCodeCredential
} from "@codevisor/adapter-opencode"
import type { HarnessAccountContext } from "@codevisor/agent-runtime"
import type { SharedCredentialVault, SharedTokenBundle } from "@codevisor/harness-manager"

import type { SharedProviderStore } from "./shared-provider-store.js"

/// OpenCode 2 keeps credentials in its own database, so a shared profile's
/// sign-ins are seeded there (into an isolated data directory) instead of
/// written to auth.json.

export interface OpenCode2Deps {
  /// OpenCode's major version as the given environment resolves `opencode`.
  readonly majorVersion: (env: NodeJS.ProcessEnv) => Promise<number | undefined>
  readonly syncCredentials: ReturnType<typeof makeOpenCode2Accounts>["syncCredentials"]
}

/// The `opencode` binary an environment runs: the newest installed, as
/// OpenCode's chats run.
const locateOpenCode = makeOpenCodeLocator()

export const makeOpenCode2Deps = (): OpenCode2Deps => {
  const version = makeOpenCodeVersionProbe()
  const accounts = makeOpenCode2Accounts({ pool: makeOpenCodeServerPool() })
  return {
    majorVersion: async (env) => {
      const command = locateOpenCode(env)
      return command === undefined ? undefined : version(command)
    },
    syncCredentials: accounts.syncCredentials
  }
}

/// Providers whose refresh goes through Codevisor's plugin, and so need a
/// broker capability in place of their refresh token.
export const refreshedThroughCodevisor = (providerId: string): boolean =>
  OPENCODE_MANAGED_METHODS.some(([integrationID]) => integrationID === providerId)

const text = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined

/// The credential OpenCode 2 stores for one shared sign-in, or undefined for
/// a provider it can't take. `capability` replaces the refresh token for a
/// provider Codevisor refreshes.
export const seededOAuthCredential = (
  token: SharedTokenBundle,
  capability: string | undefined
): SeededOpenCodeCredential | undefined => {
  const native = token.credential as Record<string, unknown>
  const oauth = (methodID: string, refresh: string, metadata: Record<string, string>) => ({
    id: `${SEEDED_CREDENTIAL_PREFIX}${token.providerId}`,
    integrationID: token.providerId?.startsWith("github-copilot")
      ? "github-copilot"
      : String(token.providerId),
    value: {
      type: "oauth",
      methodID,
      refresh,
      access: token.accessToken,
      expires: token.expiresAt,
      ...(Object.keys(metadata).length === 0 ? {} : { metadata })
    }
  })
  if (token.providerId?.startsWith("github-copilot")) {
    // Copilot's stored GitHub token is long-lived: OpenCode exchanges it
    // itself and never refreshes it.
    const enterpriseUrl = text(native.enterpriseUrl)
    return oauth("device", token.accessToken, enterpriseUrl ? { enterpriseUrl } : {})
  }
  if (capability === undefined || !refreshedThroughCodevisor(String(token.providerId)))
    return undefined
  const refresh = `codevisor:${capability}`
  if (token.providerId === "openai") {
    const accountID = text(native.accountId) ?? token.organizationId
    return oauth("chatgpt-browser", refresh, accountID ? { accountID } : {})
  }
  return oauth("device", refresh, {})
}

/// API keys from the profile's credential document, as OpenCode 2 keys.
export const seededKeyCredentials = (
  document: Readonly<Record<string, unknown>>
): Array<SeededOpenCodeCredential> =>
  Object.entries(document).flatMap(([providerId, entry]) => {
    const { type, key } = (entry ?? {}) as { type?: unknown; key?: unknown }
    return type === "api" && typeof key === "string" && key.length > 0
      ? [
          {
            id: `${SEEDED_CREDENTIAL_PREFIX}key-${providerId}`,
            integrationID: providerId,
            value: { type: "key", key }
          }
        ]
      : []
  })

/// Builds a shared profile's OpenCode 2 runtime: an isolated data directory
/// whose database holds the shared sign-ins, refreshed through Codevisor's
/// plugin. Seeding replaces them with current tokens on every session, so
/// none is near expiry while OpenCode starts (its built-in sign-ins resolve
/// their credentials before plugins load).
export const makeOpenCode2Materializer =
  (deps: {
    readonly vault: SharedCredentialVault
    /// The token service the plugin refreshes through.
    readonly url: string
    readonly capabilityFor: (
      profile: string,
      row: Awaited<ReturnType<SharedProviderStore["records"]>>[number]
    ) => Promise<{ readonly capability: string }>
    readonly writePrivate: (path: string, content: string) => Promise<void>
    readonly openCode2: OpenCode2Deps
  }) =>
  async (
    profile: string,
    root: string,
    base: HarnessAccountContext,
    env: NodeJS.ProcessEnv,
    rows: Awaited<ReturnType<SharedProviderStore["records"]>>,
    document: Readonly<Record<string, unknown>>
  ): Promise<HarnessAccountContext> => {
    const plugin = join(root, "plugin")
    for (const [name, content] of Object.entries(openCodeCredentialPluginFiles))
      await deps.writePrivate(join(plugin, name), content)
    const config = env.OPENCODE_CONFIG_CONTENT
      ? (JSON.parse(env.OPENCODE_CONFIG_CONTENT) as Record<string, unknown>)
      : {}
    const runtimeEnv: Record<string, string> = {
      ...base.env,
      XDG_DATA_HOME: join(root, "data"),
      OPENCODE_CONFIG_CONTENT: JSON.stringify({
        ...config,
        plugins: [
          ...(Array.isArray(config.plugins) ? config.plugins : []),
          { package: plugin, options: { broker: deps.url } }
        ]
      })
    }
    const seeded = seededKeyCredentials(document)
    for (const row of rows) {
      // An unavailable provider is left out; OpenCode asks to sign in.
      const token = await deps.vault.token(row.credential).catch(() => undefined)
      if (!token) continue
      const cap = refreshedThroughCodevisor(row.providerId)
        ? await deps.capabilityFor(profile, row)
        : undefined
      const credential = seededOAuthCredential(token, cap?.capability)
      if (credential) seeded.push(credential)
    }
    const sessionEnv = { ...env, ...runtimeEnv }
    await deps.openCode2.syncCredentials(
      {
        command: locateOpenCode(sessionEnv) ?? "opencode",
        cwd: env.HOME ?? root,
        env: sessionEnv
      },
      seeded
    )
    return { ...base, env: runtimeEnv }
  }
