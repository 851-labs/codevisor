import {
  makeAcpProvider,
  makeStdioAcpConnectorWithOptions,
  type AcpConnector
} from "@codevisor/adapter-acp"
import type {
  AgentProvider,
  BackgroundTerminalIntegration,
  ProviderEnvironment
} from "@codevisor/agent-runtime"
import { makeGrokBuildExtension } from "./extension.js"

export interface GrokBuildProviderConfig {
  readonly connector?: AcpConnector
  readonly authProbeTimeoutMs?: number
  readonly connectTimeoutMs?: number
  readonly backgroundTerminals?: BackgroundTerminalIntegration
}

export const makeGrokBuildProvider = (
  environment: ProviderEnvironment,
  config: GrokBuildProviderConfig = {}
): AgentProvider => {
  const connector =
    config.connector ??
    makeStdioAcpConnectorWithOptions({
      extension: makeGrokBuildExtension,
      terminalCommandMode: "shell",
      ...(config.backgroundTerminals === undefined
        ? {}
        : { backgroundTerminals: config.backgroundTerminals }),
      ...(config.connectTimeoutMs === undefined
        ? {}
        : { connectTimeoutMs: config.connectTimeoutMs })
    })
  return makeAcpProvider(environment, {
    connector,
    providerId: "grok-build",
    ...(config.authProbeTimeoutMs === undefined
      ? {}
      : { authProbeTimeoutMs: config.authProbeTimeoutMs })
  })
}
