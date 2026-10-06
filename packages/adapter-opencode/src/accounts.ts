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
