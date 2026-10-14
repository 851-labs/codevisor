import { makeAcpProvider, makeStdioAcpConnectorWithOptions } from "@codevisor/adapter-acp"
import type { AgentProvider, ProviderEnvironment } from "@codevisor/agent-runtime"

import { makeGrokBuildExtension } from "./extension.js"
import { withGrokSkillsDisabled } from "./skills.js"

export const makeGrokBuildProvider = (environment: ProviderEnvironment): AgentProvider =>
  makeAcpProvider(environment, {
    connector: makeStdioAcpConnectorWithOptions({ extension: makeGrokBuildExtension }),
    providerId: "grok-build",
    launchEnv: (env, launch) => withGrokSkillsDisabled(env, launch)
  })
