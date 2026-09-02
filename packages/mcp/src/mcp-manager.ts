import { detectMcpAuth } from "./mcp-auth-detection.js"
import { makeMcpGateway } from "./mcp-gateway.js"
import { makeMcpBrowserOperations } from "./mcp-manager-browser.js"
import { makeMcpManagerCore } from "./mcp-manager-core.js"
import { makeMcpGatewayOperations } from "./mcp-manager-gateway.js"
import { makeMcpOAuthFlows } from "./mcp-manager-oauth-flows.js"
import { makeMcpReplicationOperations } from "./mcp-manager-replication.js"
import { makeMcpServerOperations } from "./mcp-manager-servers.js"
import type { McpManager, McpManagerConfig } from "./mcp-manager-types.js"
import { makeMcpOAuthRuntime } from "./mcp-oauth.js"
import { reportBackgroundFailure, run } from "./mcp-support.js"
import { makeConnectUpstream } from "./mcp-upstream.js"

export { automationSkillPath } from "./mcp-automation-builtins.js"
export type { ToolGatewayConfig } from "./mcp-gateway.js"
export type { PluginGatewayTool, PluginToolSource } from "./mcp-plugin-tools.js"
export { NodeStreamableHttpTransport } from "./mcp-http-transport.js"
export { boundedMcpTimerDelay } from "./mcp-oauth.js"

export const makeMcpManager = (config: McpManagerConfig): McpManager => {
  const core = makeMcpManagerCore(config)
  const connectUpstream = makeConnectUpstream(core)

  const { allTools, createGatewayConnection, gatewayRuntime, refreshGatewayInventories } =
    makeMcpGateway({
      automationProviders: core.automationProviders,
      browserSetupBroker: core.browserSetupBroker,
      codeExecutor: core.codeExecutor,
      codevisorProvider: core.codevisorProvider,
      config,
      connectUpstream,
      gateways: core.gateways,
      isSuppressed: (name) => core.state.locallySuppressed.has(name),
      record: core.record
    })

  // Plugin installs/uninstalls change the plugin-tool inventory the gateway
  // advertises; refresh every live gateway's tool descriptions on change.
  const unsubscribePluginTools = config.pluginTools?.subscribeInstalled(() => {
    /* v8 ignore next 2 -- inventory refresh failures surface only from a live plugin installer. */
    void refreshGatewayInventories().catch((cause: unknown) =>
      reportBackgroundFailure("Plugin tool inventory refresh failed", cause)
    )
  })

  const { oauthProvider, scheduleRefresh, validateOAuthConnection } = makeMcpOAuthRuntime({
    callbackUrl: core.callbackUrl,
    closeConnection: core.closeConnection,
    connectUpstream,
    onRotated: core.emitCredentialsRotated,
    record: core.record,
    refreshGatewayInventories,
    refreshLocks: core.refreshLocks,
    refreshRetryAttempts: core.refreshRetryAttempts,
    refreshTimers: core.refreshTimers,
    replaceSecrets: core.replaceSecrets,
    saveRecord: core.saveRecord,
    secrets: core.secrets,
    selfServerId: core.selfServerId
  })

  const manager: McpManager = {
    detectAuth: detectMcpAuth,
    ...makeMcpServerOperations(core, { allTools, connectUpstream, refreshGatewayInventories }),
    ...makeMcpReplicationOperations(core),
    ...makeMcpOAuthFlows(core, { oauthProvider, validateOAuthConnection }),
    ...makeMcpGatewayOperations(core, {
      createGatewayConnection,
      gatewayRuntime,
      unsubscribePluginTools
    }),
    ...makeMcpBrowserOperations(core)
  }

  /* v8 ignore start -- startup token restoration feeds the live OAuth refresh scheduler above. */
  void run(config.db.listMcpServers)
    .then((servers) => {
      for (const server of servers) {
        const oauth = core.secrets(server).oauth
        if (oauth?.tokens !== undefined) scheduleRefresh(server, oauth.tokens)
      }
    })
    .catch((cause: unknown) => reportBackgroundFailure("MCP OAuth restoration failed", cause))
  /* v8 ignore stop */

  return manager
}
