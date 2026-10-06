import { makeAcpProvider, type AcpConnector } from "@codevisor/adapter-acp"
import type {
  AgentProvider,
  BackgroundTerminalIntegration,
  ProviderEnvironment
} from "@codevisor/agent-runtime"

export interface OpenCodeProviderConfig {
  readonly connector?: AcpConnector
  readonly backgroundTerminals?: BackgroundTerminalIntegration
}

/// OpenCode's own provider. Every OpenCode version still runs its chats
/// over ACP; OpenCode-specific behavior (OpenCode 2's native server and
/// credentials) lands here rather than as special cases in generic ACP.
export const makeOpenCodeProvider = (
  environment: ProviderEnvironment,
  config: OpenCodeProviderConfig = {}
): AgentProvider => makeAcpProvider(environment, { ...config, providerId: "opencode" })
