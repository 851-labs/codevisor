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
        : { backgroundTerminals: config.backgroundTerminals })
    })
  return makeAcpProvider(environment, {
    connector,
    providerId: "cursor"
  })
}
