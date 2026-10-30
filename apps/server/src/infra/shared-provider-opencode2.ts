import { join } from "node:path"

import {
  claudeAgentCredential,
  claudeAgentEnv,
  claudeAgentLauncher,
  makeOpenCode2Accounts,
  makeOpenCodeLocator,
  makeOpenCodeServerPool,
  makeOpenCodeVersionProbe,
  openCodeCredentialPluginFiles,
  OPENCODE_MANAGED_METHODS,
  SEEDED_CREDENTIAL_PREFIX,
  type ClaudeAgentLaunch,
  type SeededOpenCodeCredential
} from "@codevisor/adapter-opencode"
import type { HarnessAccountContext } from "@codevisor/agent-runtime"
import {
  openCodeConsoleServer,
  type SharedCredentialVault,
  type SharedTokenBundle
} from "@codevisor/harness-manager"

import { asRecord, field, recordField } from "../unknown-values.js"
import type { SharedProviderStore } from "./shared-provider-store.js"

export interface OpenCode2Deps {
  readonly majorVersion: (env: NodeJS.ProcessEnv) => Promise<number | undefined>
  readonly syncCredentials: ReturnType<typeof makeOpenCode2Accounts>["syncCredentials"]
}

const locateOpenCode = makeOpenCodeLocator()

export const makeOpenCode2Deps = (): OpenCode2Deps => {
  const version = makeOpenCodeVersionProbe()
  const accounts = makeOpenCode2Accounts({ pool: makeOpenCodeServerPool() })
  return {
    majorVersion: async (env) => {
      const command = locateOpenCode(env)
      if (command === undefined) return undefined
      return version(command)
    },
    syncCredentials: accounts.syncCredentials
  }
}

export const refreshedThroughCodevisor = (providerId: string): boolean =>
  OPENCODE_MANAGED_METHODS.some(([integrationID]) => integrationID === providerId)

const text = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined

const CONSOLE_METADATA = ["accountID", "email", "orgID", "orgName"]

const consoleMetadata = (
  metadata: Readonly<Record<string, unknown>>
): Record<string, string> | undefined => {
  const server = openCodeConsoleServer(metadata.server)
  if (server === undefined) return undefined
  return Object.fromEntries([
    ["server", server],
    ...CONSOLE_METADATA.flatMap((key) => {
      const value = text(metadata[key])
      return value === undefined ? [] : [[key, value]]
    })
  ])
}

export const seededOAuthCredential = (
  token: SharedTokenBundle,
  capability: string | undefined
): SeededOpenCodeCredential | undefined => {
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
    const enterpriseUrl = text(field(token.credential, "enterpriseUrl"))
    return oauth("device", token.accessToken, enterpriseUrl ? { enterpriseUrl } : {})
  }
  if (capability === undefined || !refreshedThroughCodevisor(String(token.providerId)))
    return undefined
  const refresh = `codevisor:${capability}`
  if (token.providerId === "openai") {
    const accountID = text(field(token.credential, "accountId")) ?? token.organizationId
    return oauth("chatgpt-browser", refresh, accountID ? { accountID } : {})
  }
  if (token.providerId === "opencode") {
    const metadata = consoleMetadata(recordField(token.credential, "metadata"))
    return metadata === undefined ? undefined : oauth("device", refresh, metadata)
  }
  return oauth("device", refresh, {})
}

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

const claudeAgentRuntimeEnv = async (
  writeExecutable: (path: string, content: string) => Promise<void>,
  root: string,
  claude: ClaudeAgentLaunch
): Promise<Record<string, string>> => {
  const launcher = join(root, "claude")
  await writeExecutable(launcher, claudeAgentLauncher)
  return claudeAgentEnv(launcher, claude)
}

const claudeAgentSeeds = (claude: ClaudeAgentLaunch | undefined) =>
  claude === undefined ? [] : [claudeAgentCredential]

export const makeOpenCode2Materializer =
  (deps: {
    readonly vault: SharedCredentialVault
    readonly url: string
    readonly capabilityFor: (
      profile: string,
      row: Awaited<ReturnType<SharedProviderStore["records"]>>[number]
    ) => Promise<{ readonly capability: string }>
    readonly writePrivate: (path: string, content: string) => Promise<void>
    readonly writeExecutable: (path: string, content: string) => Promise<void>
    readonly openCode2: OpenCode2Deps
  }) =>
  async (
    profile: string,
    root: string,
    base: HarnessAccountContext,
    env: NodeJS.ProcessEnv,
    rows: Awaited<ReturnType<SharedProviderStore["records"]>>,
    document: Readonly<Record<string, unknown>>,
    claude?: ClaudeAgentLaunch
  ): Promise<HarnessAccountContext> => {
    const plugin = join(root, "plugin")
    for (const [name, content] of Object.entries(openCodeCredentialPluginFiles))
      await deps.writePrivate(join(plugin, name), content)
    const config = env.OPENCODE_CONFIG_CONTENT
      ? asRecord(JSON.parse(env.OPENCODE_CONFIG_CONTENT))
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
    if (claude !== undefined)
      Object.assign(runtimeEnv, await claudeAgentRuntimeEnv(deps.writeExecutable, root, claude))
    const seeded = [...claudeAgentSeeds(claude), ...seededKeyCredentials(document)]
    for (const row of rows) {
      const token = await deps.vault.token(row.credential).catch(() => undefined)
      if (!token) continue
      let cap: { readonly capability: string } | undefined
      if (refreshedThroughCodevisor(row.providerId)) cap = await deps.capabilityFor(profile, row)
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
