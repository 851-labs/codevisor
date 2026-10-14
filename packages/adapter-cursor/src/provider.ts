import { makeAcpProvider, makeStdioAcpConnectorWithOptions } from "@codevisor/adapter-acp"
import type { AgentProvider, ProviderEnvironment } from "@codevisor/agent-runtime"

import { makeCursorExtension } from "./extension.js"

export const makeCursorProvider = (environment: ProviderEnvironment): AgentProvider =>
  makeAcpProvider(environment, {
    connector: makeStdioAcpConnectorWithOptions({ extension: makeCursorExtension }),
    providerId: "cursor"
  })
