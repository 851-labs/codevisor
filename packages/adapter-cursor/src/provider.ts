import {
  makeAcpProvider,
  makeStdioAcpConnectorWithOptions,
  type AcpConnector
} from "@codevisor/adapter-acp"
import type { AgentProvider, ProviderEnvironment } from "@codevisor/agent-runtime"

import { makeCursorExtension } from "./extension.js"

export interface CursorProviderConfig {
  readonly connector?: AcpConnector
}

export const makeCursorProvider = (
  environment: ProviderEnvironment,
  config: CursorProviderConfig = {}
): AgentProvider => {
  const connector =
    config.connector ?? makeStdioAcpConnectorWithOptions({ extension: makeCursorExtension })
  return makeAcpProvider(environment, {
    connector,
    providerId: "cursor"
  })
}
