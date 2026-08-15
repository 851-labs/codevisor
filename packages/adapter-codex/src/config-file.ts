import { readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { parse as parseToml } from "smol-toml"
import { isRecord } from "./internal.js"

/// Codex's own bundled automation servers (written into the user's
/// `config.toml` by the Codex desktop app). Codevisor turns them off inside
/// its threads so automation routes through the Codevisor tool gateway.
export const NATIVE_AUTOMATION_MCP_SERVERS = ["node_repl", "computer-use"] as const

export const defaultConfigFileReader = (path: string): string | undefined => {
  try {
    return readFileSync(path, "utf8")
  } catch {
    return undefined
  }
}

/// Server names defined under `[mcp_servers]` in the codex home's
/// `config.toml`. Thread-config overrides deep-merge into that file, so an
/// `{ enabled: false }` stub is only valid for servers that already exist
/// there — a stub without a base entry becomes a transport-less server that
/// the Codex app-server rejects at config load ("invalid transport").
export const configuredMcpServerNames = (
  env: NodeJS.ProcessEnv,
  readConfigFile: (path: string) => string | undefined
): ReadonlySet<string> => {
  const codexHome =
    env.CODEX_HOME !== undefined && env.CODEX_HOME.trim() !== ""
      ? env.CODEX_HOME
      : join(homedir(), ".codex")
  const content = readConfigFile(join(codexHome, "config.toml"))
  if (content === undefined) return new Set()
  try {
    const parsed: unknown = parseToml(content)
    if (!isRecord(parsed) || !isRecord(parsed.mcp_servers)) return new Set()
    return new Set(Object.keys(parsed.mcp_servers))
  } catch {
    // An unparseable config fails codex's own load loudly; nothing to
    // disable from here.
    return new Set()
  }
}
