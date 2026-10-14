import {
  makeAcpProvider,
  makeStdioAcpConnectorWithOptions,
  type AcpConnector
} from "@codevisor/adapter-acp"
import {
  OPENCODE_INSTALL_PATH,
  type AgentProvider,
  type ProviderEnvironment
} from "@codevisor/agent-runtime"

import { makeOpenCodeLocator } from "./binary.js"
import { makeOpenCodeExtension } from "./extension.js"
import { withOpenCodePermissions } from "./permissions.js"

const OPENCODE_NAMES = new Set(["opencode", OPENCODE_INSTALL_PATH])

export interface OpenCodeProviderConfig {
  readonly connector?: AcpConnector
  readonly locateOpenCode?: (env: NodeJS.ProcessEnv) => string | undefined
}

export const makeOpenCodeProvider = (
  environment: ProviderEnvironment,
  config: OpenCodeProviderConfig = {}
): AgentProvider => {
  const { locateOpenCode = makeOpenCodeLocator(), ...acp } = config
  const connector =
    acp.connector ?? makeStdioAcpConnectorWithOptions({ extension: makeOpenCodeExtension })
  const opencode: ProviderEnvironment = {
    get env() {
      return environment.env
    },
    executableExists: environment.executableExists,
    locateExecutable: (name, env) =>
      (OPENCODE_NAMES.has(name) ? locateOpenCode(env) : undefined) ??
      environment.locateExecutable(name, env)
  }
  return makeAcpProvider(opencode, {
    ...acp,
    connector,
    providerId: "opencode",
    launchEnv: withOpenCodePermissions
  })
}
