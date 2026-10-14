import { mkdir } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"

import type { HarnessAccountContext } from "@codevisor/agent-runtime"
import type { HarnessAccountRecord } from "@codevisor/db"
import type { SharedTokenBundle } from "@codevisor/harness-manager"

import type { SharedHarnessAccount } from "./shared-account-store.js"
import { antigravitySharedContext } from "./shared-antigravity.js"
import { museSharedContext } from "./shared-muse.js"

/// How a shared account runs on this machine: the profile its harness uses
/// and the environment that hands it the synced sign-in.
export const sharedAccountContext = async (
  deps: {
    readonly dataDir: string
    readonly baseUrl: string
    readonly environment: () => Promise<NodeJS.ProcessEnv>
    readonly token: (id: string, rejected?: string) => Promise<SharedTokenBundle>
    readonly gateway: { readonly register: (id: string, accessToken: string) => void }
    /// The local row `id` names (the adopted original, for an alias).
    readonly record: (id: string) => Promise<HarnessAccountRecord | undefined>
  },
  account: SharedHarnessAccount,
  id: string,
  bundle: SharedTokenBundle
): Promise<HarnessAccountContext> => {
  let path = join(deps.dataDir, "harness-profiles", account.harnessId, account.id)
  // Existing Codex threads stay in their original local profile. External
  // token mode changes authentication in memory without moving transcripts.
  // An adopted Antigravity account keeps its profile too: agy's
  // conversations live in its data root.
  if ((account.harnessId === "codex" || account.harnessId === "antigravity") && id !== account.id) {
    const original = await deps.record(id)
    if (original?.profileKind === "managed")
      path = join(
        deps.dataDir,
        "harness-profiles",
        account.harnessId,
        original.profileKey ?? original.id
      )
    else if (account.harnessId === "codex" && original?.profileKind === "default") {
      const env = await deps.environment()
      path = env.CODEX_HOME ?? join(env.HOME ?? homedir(), ".codex")
    }
  }
  await mkdir(path, { recursive: true, mode: 0o700 })
  if (account.harnessId === "muse-code")
    return museSharedContext(account.id, path, bundle, await deps.environment())
  if (account.harnessId === "antigravity")
    return antigravitySharedContext(account.id, path, bundle, await deps.environment())
  if (bundle.authMethod === "apiKey")
    return {
      id: account.id,
      profileKind: "managed",
      env:
        account.harnessId === "codex"
          ? { CODEX_HOME: path, OPENAI_API_KEY: bundle.accessToken }
          : {
              CLAUDE_CONFIG_DIR: path,
              ANTHROPIC_API_KEY: bundle.accessToken
            }
    }
  if (account.harnessId === "codex")
    return {
      id: account.id,
      profileKind: "managed",
      env: { CODEX_HOME: path },
      oauth: {
        token: async (rejected) => {
          const current = await deps.token(account.id, rejected)
          return {
            accessToken: current.accessToken,
            ...(current.organizationId ? { accountId: current.organizationId } : {}),
            ...(current.planType ? { planType: current.planType } : {})
          }
        }
      }
    }
  deps.gateway.register(account.id, bundle.accessToken)
  return {
    id: account.id,
    profileKind: "managed",
    env: {
      CLAUDE_CONFIG_DIR: path,
      CLAUDE_CODE_OAUTH_TOKEN: bundle.accessToken,
      ANTHROPIC_BASE_URL: `${deps.baseUrl}/harness/claude`
    }
  }
}
