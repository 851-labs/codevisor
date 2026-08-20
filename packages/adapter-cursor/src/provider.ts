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
import { makeCursorExtension } from "./extension.js"

export interface CursorProviderConfig {
  readonly connector?: AcpConnector
  readonly authProbeTimeoutMs?: number
  readonly connectTimeoutMs?: number
  readonly backgroundTerminals?: BackgroundTerminalIntegration
}

export const makeCursorProvider = (
  environment: ProviderEnvironment,
  config: CursorProviderConfig = {}
): AgentProvider => {
  const connector =
    config.connector ??
    makeStdioAcpConnectorWithOptions({
      extension: makeCursorExtension,
      ...(config.backgroundTerminals === undefined
        ? {}
        : { backgroundTerminals: config.backgroundTerminals }),
      ...(config.connectTimeoutMs === undefined
        ? {}
        : { connectTimeoutMs: config.connectTimeoutMs })
    })
  return makeAcpProvider(environment, {
    connector,
    providerId: "cursor",
    ...(config.authProbeTimeoutMs === undefined
      ? {}
      : { authProbeTimeoutMs: config.authProbeTimeoutMs })
  })
}
