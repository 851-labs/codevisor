import { openCodeProvidersFromIntegrations, type OpenCodeIntegration } from "./integrations.js"
import type { makeOpenCodeServerPool } from "./pool.js"
import { startOpenCodeServer, type OpenCodeServer, type OpenCodeServerOptions } from "./server.js"

export interface OpenCodeProfileRuntime {
  readonly command: string
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
}

export interface SeededOpenCodeCredential {
  readonly id: string
  readonly integrationID: string
  readonly value: Readonly<Record<string, unknown>>
}

export const SEEDED_CREDENTIAL_PREFIX = "codevisor-"

export const makeOpenCode2Accounts = (deps: {
  readonly pool: ReturnType<typeof makeOpenCodeServerPool>
  readonly start?: (options: OpenCodeServerOptions) => Promise<OpenCodeServer>
}) => {
  const start = deps.start ?? startOpenCodeServer
  const hold = (profile: OpenCodeProfileRuntime) =>
    deps.pool.acquire(
      JSON.stringify([profile.command, profile.env.XDG_DATA_HOME ?? profile.env.HOME]),
      () => start({ command: profile.command, env: profile.env, cwd: profile.cwd })
    )
  const withServer = async <A>(
    profile: OpenCodeProfileRuntime,
    use: (server: OpenCodeServer) => Promise<A>
  ): Promise<A> => {
    const lease = await hold(profile)
    try {
      return await use(lease.server)
    } finally {
      lease.release()
    }
  }
  return {
    hold,
    removeIntegration: (profile: OpenCodeProfileRuntime, integrationID: string) =>
      withServer(profile, async (server) => {
        const stored = await server.request<{
          readonly data: ReadonlyArray<{ readonly id: string; readonly integrationID: string }>
        }>("/api/credential")
        for (const { id } of stored.data.filter((entry) => entry.integrationID === integrationID))
          await server.request(`/api/credential/${encodeURIComponent(id)}`, { method: "DELETE" })
      }),
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
