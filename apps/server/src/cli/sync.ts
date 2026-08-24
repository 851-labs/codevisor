import { resolvePort, type CliDeps, type CommandOptions } from "./support.js"

/// `codevisor sync [status|on|off]` — this machine's config-plane
/// participation. The flag lives in the server's database (see
/// /v1/sync-participation) and is enforced there: while off, every sync
/// surface on this machine refuses, so no client can gossip past the
/// owner's choice. These commands are thin loopback calls; the onboarding
/// flows (`codevisor auth login`, `codevisor setup`) reuse the same apply.

export interface SyncCommandOptions extends CommandOptions {
  /// undefined reads the current state; true/false sets it.
  readonly enabled?: boolean | undefined
}

const participationUrl = (port: number): string => `http://127.0.0.1:${port}/v1/sync-participation`

/// Applies the participation choice via the local server; false when the
/// server is unreachable (callers decide how loudly to say so).
export const applySyncParticipation = async (
  deps: CliDeps,
  enabled: boolean,
  port?: number
): Promise<boolean> => {
  const resolved = await resolvePort(deps, port)
  const response = await deps.fetchJson(participationUrl(resolved), {
    method: "PUT",
    body: { enabled }
  })
  return response !== undefined && response.status === 200
}

export const syncCommand = async (
  deps: CliDeps,
  options: SyncCommandOptions = {}
): Promise<number> => {
  const port = await resolvePort(deps, options.port)
  if (options.enabled === undefined) {
    const response = await deps.fetchJson(participationUrl(port))
    if (response === undefined || response.status !== 200) {
      deps.error(`Codevisor server is not running on port ${port}; start it first: codevisor start`)
      return 1
    }
    const enabled = (response.body as { readonly enabled?: boolean }).enabled === true
    deps.log(`Config sync is ${enabled ? "on" : "off"} for this machine.`)
    return 0
  }
  if (!(await applySyncParticipation(deps, options.enabled, options.port))) {
    deps.error(`Codevisor server is not running on port ${port}; start it first: codevisor start`)
    return 1
  }
  deps.log(`Config sync is now ${options.enabled ? "on" : "off"} for this machine.`)
  return 0
}
