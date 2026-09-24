import { makeNativeMcpEditor } from "./native-mcp-edits.js"
import { makeNativeMcpImporter } from "./native-mcp-import.js"
import { makeNativeMcpScanner, type NativeMcpEnvironment } from "./native-mcp-scan.js"
import type { NativeMcpManager, NativeMcpManagerConfig } from "./native-mcp-types.js"

export const makeNativeMcpManager = (config: NativeMcpManagerConfig): NativeMcpManager => {
  const environment: NativeMcpEnvironment = {
    fs: config.fs,
    home: config.homedir,
    env: config.env
  }
  const scanner = makeNativeMcpScanner(config, environment)
  const { importServers } = makeNativeMcpImporter(config, scanner)
  const editor = makeNativeMcpEditor(config, environment, scanner.scan)
  return { importServers, scan: scanner.scan, ...editor }
}
