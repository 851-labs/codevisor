import {
  makeAcpProvider,
  makeStdioAcpConnectorWithOptions,
  type AcpConnector
} from "@codevisor/adapter-acp"
import type { AgentProvider, ProviderEnvironment } from "@codevisor/agent-runtime"

import { makeGrokBuildExtension } from "./extension.js"
import { readGrokConfigFile, withGrokSkillsDisabled } from "./skills.js"

export interface GrokBuildProviderConfig {
  readonly connector?: AcpConnector
  readonly readConfigFile?: (path: string) => string | undefined
}

export const makeGrokBuildProvider = (
  environment: ProviderEnvironment,
  config: GrokBuildProviderConfig = {}
): AgentProvider => {
  const connector =
    config.connector ?? makeStdioAcpConnectorWithOptions({ extension: makeGrokBuildExtension })
  const readConfigFile = config.readConfigFile ?? readGrokConfigFile
  return makeAcpProvider(environment, {
    connector,
    providerId: "grok-build",
    launchEnv: (env, launch) => withGrokSkillsDisabled(env, launch, readConfigFile)
  })
}
