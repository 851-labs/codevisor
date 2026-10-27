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

const withGrokNativeAgentsDisabled = (env: NodeJS.ProcessEnv): NodeJS.ProcessEnv => ({
  ...env,
  GROK_SUBAGENTS: "0",
  GROK_WORKFLOWS: "0"
})

export const makeGrokBuildProvider = (
  environment: ProviderEnvironment,
  config: GrokBuildProviderConfig = {}
): AgentProvider =>
  makeAcpProvider(environment, {
    connector:
      config.connector ?? makeStdioAcpConnectorWithOptions({ extension: makeGrokBuildExtension }),
    providerId: "grok-build",
    launchEnv: (env, launch) => withGrokNativeAgentsDisabled(withGrokSkillsDisabled(env, launch)),
    readUsageLimits: readGrokUsageLimits
  })
