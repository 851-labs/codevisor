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

  const serverOperations = makeMcpServerOperations(core, {
    allTools,
    connectUpstream,
    refreshGatewayInventories
  })
  const manager: McpManager = {
    detectAuth: detectMcpAuth,
    ...serverOperations,
    ...makeMcpReplicationOperations(core, { scheduleRefresh, connect: serverOperations.connect }),
    ...makeMcpOAuthFlows(core, { oauthProvider, validateOAuthConnection }),
    ...makeMcpGatewayOperations(core, {
      createGatewayConnection,
      gatewayRuntime,
      unsubscribePluginTools
    }),
    ...makeMcpBrowserOperations(core)
  }

  void run(config.db.listMcpServers)
    .then((servers) => {
      for (const server of servers) {
        const oauth = core.secrets(server).oauth
        if (oauth?.tokens === undefined) continue
        scheduleRefresh(server, oauth.tokens)
        // A mirror that received tokens but never tried them (older builds
        // stopped at the import) heals on boot: enabled, credentialed, and
        // still reporting "needs authorization" means "connect now".
        if (server.enabled && server.connectionState === "needsAuthorization") {
          /* v8 ignore next -- a refused boot reconnect already reports through the record's state. */
          void serverOperations.connect(server.id).catch(() => undefined)
        }
      }
    })
    /* v8 ignore start -- listing the manager's own table only fails on a broken database. */
    .catch((cause: unknown) => reportBackgroundFailure("MCP OAuth restoration failed", cause))
  /* v8 ignore stop */

  return manager
}
