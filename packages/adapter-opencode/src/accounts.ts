import { openCodeProvidersFromIntegrations, type OpenCodeIntegration } from "./integrations.js"
import type { makeOpenCodeServerPool } from "./pool.js"
import { startOpenCodeServer, type OpenCodeServer, type OpenCodeServerOptions } from "./server.js"

/// OpenCode 2 account operations for one profile: its binary, environment
/// (whose XDG data directory holds its credentials) and working directory.

export interface OpenCodeProfileRuntime {
  readonly command: string
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
}

/// A credential Codevisor keeps in a profile's OpenCode database.
export interface SeededOpenCodeCredential {
  readonly id: string
  readonly integrationID: string
  readonly value: Readonly<Record<string, unknown>>
}

/// Ids of every credential Codevisor seeds, so its own are told apart from
/// ones the user added in OpenCode.
export const SEEDED_CREDENTIAL_PREFIX = "codevisor-"

export const makeOpenCode2Accounts = (deps: {
  readonly pool: ReturnType<typeof makeOpenCodeServerPool>
  readonly start?: (options: OpenCodeServerOptions) => Promise<OpenCodeServer>
}) => {
  const start = deps.start ?? startOpenCodeServer
  const withServer = async <A>(
    profile: OpenCodeProfileRuntime,
    use: (server: OpenCodeServer) => Promise<A>
  ): Promise<A> => {
    // One control server per binary and data directory: the credentials
    // live in that directory's database.
    const key = JSON.stringify([profile.command, profile.env.XDG_DATA_HOME ?? profile.env.HOME])
    const lease = await deps.pool.acquire(key, () =>
      start({ command: profile.command, env: profile.env, cwd: profile.cwd })
    )
    try {
      return await use(lease.server)
    } finally {
      lease.release()
    }
  }
  return {
    /// Makes the profile's Codevisor credentials exactly `desired`, each one
    /// replaced (OpenCode's API can't update a secret in place), so a session
    /// starts with the token Codevisor holds now.
    syncCredentials: (
      profile: OpenCodeProfileRuntime,
      desired: ReadonlyArray<SeededOpenCodeCredential>
    ) =>
      withServer(profile, async (server) => {
        const stored = await server.request<{
          readonly data: ReadonlyArray<{ readonly id: string }>
        }>("/api/credential")
        for (const { id } of stored.data) {
          if (id.startsWith(SEEDED_CREDENTIAL_PREFIX))
            await server.request(`/api/credential/${encodeURIComponent(id)}`, { method: "DELETE" })
        }
        for (const credential of desired)
          await server.request("/api/credential", {
            body: { ...credential, label: "Codevisor", activate: true }
          })
      }),
    providers: (profile: OpenCodeProfileRuntime) =>
      withServer(profile, async (server) =>
        openCodeProvidersFromIntegrations(
          (
            await server.request<{ readonly data: ReadonlyArray<OpenCodeIntegration> }>(
              "/api/integration",
              { location: profile.cwd }
            )
          ).data
        )
      )
  }
}
