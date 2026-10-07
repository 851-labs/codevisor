import { makeAcpProvider, type AcpConnector } from "@codevisor/adapter-acp"
import {
  OPENCODE_INSTALL_PATH,
  type AgentProvider,
  type BackgroundTerminalIntegration,
  type ProviderEnvironment
} from "@codevisor/agent-runtime"

import { makeOpenCodeLocator } from "./binary.js"
import { withOpenCodePermissions } from "./permissions.js"

/// What the catalog looks OpenCode up as: its name, and its installer's path.
const OPENCODE_NAMES = new Set(["opencode", OPENCODE_INSTALL_PATH])

export interface OpenCodeProviderConfig {
  readonly connector?: AcpConnector
  readonly backgroundTerminals?: BackgroundTerminalIntegration
  /// The OpenCode to run; the newest installed by default.
  readonly locateOpenCode?: (env: NodeJS.ProcessEnv) => string | undefined
}

/// OpenCode's own provider. Every OpenCode version still runs its chats
/// over ACP; OpenCode-specific behavior (OpenCode 2's native server and
/// credentials, full-access permissions) lands here rather than as special
/// cases in generic ACP.
export const makeOpenCodeProvider = (
  environment: ProviderEnvironment,
  config: OpenCodeProviderConfig = {}
): AgentProvider => {
  const { locateOpenCode = makeOpenCodeLocator(), ...acp } = config
  // OpenCode is launched by name; answer it with the newest install. A
  // getter, so environment refreshes still reach the provider.
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
    providerId: "opencode",
    launchEnv: withOpenCodePermissions
  })
}
