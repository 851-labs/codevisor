import {
  TRUSTED_LAUNCH,
  type HarnessAccountContext,
  type ProviderEnvironment,
  type ToolGatewayConfig
} from "@codevisor/agent-runtime"

import { configuredMcpServerNames, NATIVE_AUTOMATION_MCP_SERVERS } from "./config-file.js"
import { DISABLED_CODEX_PLUGIN, NATIVE_CODEX_PLUGIN_SKILL_NAMES } from "./skills.js"

export interface ThreadConfigSources {
  readonly environment: ProviderEnvironment
  readonly readConfigFile: (path: string) => string | undefined
  readonly account: HarnessAccountContext | undefined
  readonly toolGateway: ToolGatewayConfig | undefined
}

export const codexThreadConfig = (sources: ThreadConfigSources): Record<string, unknown> => {
  const configuredServers = configuredServerNames(sources)
  const nativeAutomationDisables = NATIVE_AUTOMATION_MCP_SERVERS.filter(
    (name) => configuredServers?.has(name) ?? false
  )
  return {
    ...TRUSTED_LAUNCH.codexConfig,
    plugins: {
      [DISABLED_CODEX_PLUGIN]: { enabled: false }
    },
    skills: {
      bundled: { enabled: false },
      config: NATIVE_CODEX_PLUGIN_SKILL_NAMES.map((name) => ({ name, enabled: false }))
    },
    "features.browser_use": false,
    "features.browser_use_external": false,
    "features.browser_use_full_cdp_access": false,
    "features.computer_use": false,
    "features.in_app_browser": false,
    "agents.enabled": false,
    "features.multi_agent": false,
    "features.multi_agent_v2": false,
    ...gatewayMcpServers(sources.toolGateway, nativeAutomationDisables)
  }
}

const configuredServerNames = ({
  environment,
  readConfigFile,
  account,
  toolGateway
}: ThreadConfigSources): ReadonlySet<string> | undefined => {
  if (toolGateway === undefined) return undefined

  return configuredMcpServerNames({ ...environment.env, ...account?.env }, readConfigFile)
}

const GATEWAY_TOOL_TIMEOUT_SEC = 660

const gatewayMcpServers = (
  toolGateway: ToolGatewayConfig | undefined,
  nativeAutomationDisables: ReadonlyArray<string>
): { mcp_servers?: Record<string, unknown> } => {
  if (toolGateway === undefined) return {}

  return {
    mcp_servers: {
      ...Object.fromEntries(nativeAutomationDisables.map((name) => [name, { enabled: false }])),
      [toolGateway.name]: {
        url: toolGateway.url,
        bearer_token_env_var: "CODEVISOR_MCP_GATEWAY_TOKEN",
        default_tools_approval_mode: "approve",
        tool_timeout_sec: GATEWAY_TOOL_TIMEOUT_SEC
      }
    }
  }
}
