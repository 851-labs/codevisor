import type {
  CreateMcpServerRequest,
  ImportNativeMcpsRequest,
  ImportNativeMcpsResult,
  NativeMcpImportOutcome
} from "@codevisor/api"

import { errorMessage, run } from "./mcp-support.js"
import type { NormalizedNativeServer } from "./native-config-normalize.js"
import type { DiscoveredServer, NativeMcpScanner } from "./native-mcp-scan.js"
import type { NativeMcpManagerConfig } from "./native-mcp-types.js"

const placeholderWarnings = (normalized: NormalizedNativeServer): Array<string> => {
  const warnings: Array<string> = []
  for (const [key, value] of [
    ...Object.entries(normalized.env),
    ...Object.entries(normalized.headers)
  ]) {
    if (/\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/.test(value)) {
      warnings.push(
        `${key} references a shell variable and was imported verbatim — review it in the server's settings`
      )
    }
  }
  return warnings
}

export const makeNativeMcpImporter = (
  config: NativeMcpManagerConfig,
  scanner: NativeMcpScanner
): {
  readonly importServers: (request: ImportNativeMcpsRequest) => Promise<ImportNativeMcpsResult>
} => {
  const { scanDetailed } = scanner

  const managedNames = async (): Promise<Set<string>> => {
    const servers = await run(config.db.listMcpServers)
    return new Set(servers.map((server) => server.name.toLowerCase()))
  }

  const importServers = async (
    request: ImportNativeMcpsRequest
  ): Promise<ImportNativeMcpsResult> => {
    const { discovered, scan: current } = await scanDetailed()
    const names = await managedNames()
    const outcomes: Array<NativeMcpImportOutcome> = []

    for (const identity of request.identities) {
      const candidate = current.candidates.find((entry) => entry.identity === identity)
      const matches = discovered.filter((entry) => entry.row.identity === identity)
      const source = matches.find((entry) => entry.row.scope === "global") ?? matches[0]
      if (candidate === undefined || source === undefined) {
        outcomes.push({
          detail: "Not found in any harness — rescan and try again",
          identity,
          status: "failed",
          warnings: []
        })
        continue
      }
      if (candidate.alreadyManaged) {
        outcomes.push({
          detail: "Already managed by Codevisor",
          identity,
          status: "skipped",
          warnings: []
        })
        continue
      }
      try {
        outcomes.push(await importOne(identity, candidate.name, source, names))
      } catch (cause) {
        outcomes.push({
          detail: errorMessage(cause),
          identity,
          status: "failed",
          warnings: []
        })
      }
    }

    return { outcomes, scan: (await scanDetailed()).scan }
  }

  const importOne = async (
    identity: string,
    candidateName: string,
    source: DiscoveredServer,
    names: Set<string>
  ): Promise<NativeMcpImportOutcome> => {
    const { normalized, row } = source
    const warnings = placeholderWarnings(normalized)

    let name = candidateName
    if (names.has(name.toLowerCase())) {
      name = `${candidateName} (${row.harnessName})`
    }
    if (names.has(name.toLowerCase())) {
      return {
        detail: `A managed server named ${candidateName} already exists — rename it first`,
        identity,
        status: "failed",
        warnings
      }
    }

    let authType: "none" | "bearer" | "oauth" = "none"
    if (normalized.url !== undefined && Object.keys(normalized.headers).length === 0) {
      try {
        const detection = await config.mcp.detectAuth(normalized.url)
        if (detection.authType === "oauth" || detection.authType === "bearer") {
          authType = detection.authType
        }
      } catch {
        warnings.push(
          "Couldn't probe the server's authorization requirements — imported without auth; connect it from settings"
        )
      }
    }

    const createRequest: CreateMcpServerRequest = {
      args: normalized.args,
      authType,
      ...(normalized.command === undefined ? {} : { command: normalized.command }),
      enabled: true,
      ...(Object.keys(normalized.env).length === 0 ? {} : { env: normalized.env }),
      ...(Object.keys(normalized.headers).length === 0 ? {} : { headers: normalized.headers }),
      name,
      transport: normalized.transport,
      ...(normalized.url === undefined ? {} : { url: normalized.url })
    }

    const created = await config.mcp.create(createRequest)
    names.add(created.name.toLowerCase())
    return {
      identity,
      serverId: created.id,
      serverName: created.name,
      status: "imported",
      warnings
    }
  }

  return { importServers }
}
