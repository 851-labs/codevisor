import { readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

import { parse as parseToml } from "smol-toml"

import { isRecord } from "./internal.js"

export const NATIVE_AUTOMATION_MCP_SERVERS = ["node_repl", "computer-use", "cua_repl"] as const

export const defaultConfigFileReader = (path: string): string | undefined => {
  try {
    return readFileSync(path, "utf8")
  } catch {
    return undefined
  }
}

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
    return new Set()
  }
}
