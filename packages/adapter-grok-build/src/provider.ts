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
import { readGrokConfigFile, withGrokSkillsDisabled } from "./skills.js"

export interface GrokBuildProviderConfig {
  readonly connector?: AcpConnector
  readonly backgroundTerminals?: BackgroundTerminalIntegration
  /// Reads Grok's config files; exposed for tests.
  readonly readConfigFile?: (path: string) => string | undefined
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
  const readConfigFile = config.readConfigFile ?? readGrokConfigFile
  return makeAcpProvider(environment, {
    connector,
    providerId: "grok-build",
    launchEnv: (env, launch) => withGrokSkillsDisabled(env, launch, readConfigFile)
  })
}
