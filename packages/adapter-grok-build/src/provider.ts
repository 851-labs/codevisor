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
        : { backgroundTerminals: config.backgroundTerminals })
    })
  return makeAcpProvider(environment, {
    connector,
    providerId: "grok-build"
  })
}
