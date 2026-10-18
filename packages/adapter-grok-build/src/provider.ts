import {
  makeAcpProvider,
  makeStdioAcpConnectorWithOptions,
  type AcpConnector
} from "@codevisor/adapter-acp"
import type { AgentProvider, ProviderEnvironment } from "@codevisor/agent-runtime"

import { makeGrokBuildExtension } from "./extension.js"
import { withGrokSkillsDisabled } from "./skills.js"
import { readGrokUsageLimits } from "./usage.js"

export interface GrokBuildProviderConfig {
  readonly connector?: AcpConnector
}

export const makeGrokBuildProvider = (
  environment: ProviderEnvironment,
  config: GrokBuildProviderConfig = {}
): AgentProvider =>
  makeAcpProvider(environment, {
    connector:
      config.connector ?? makeStdioAcpConnectorWithOptions({ extension: makeGrokBuildExtension }),
    providerId: "grok-build",
    launchEnv: (env, launch) => withGrokSkillsDisabled(env, launch),
    readUsageLimits: readGrokUsageLimits
  })
