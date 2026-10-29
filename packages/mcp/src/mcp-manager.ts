import { detectMcpAuth } from "./mcp-auth-detection.js"
import { systemExecutionTimers } from "./mcp-gateway-execution.js"
import { makeExecutionJobs } from "./mcp-gateway-jobs.js"
import { makeMcpGateway } from "./mcp-gateway.js"
import { makeMcpBrowserOperations } from "./mcp-manager-browser.js"
import { makeMcpManagerCore } from "./mcp-manager-core.js"
import { makeMcpGatewayOperations } from "./mcp-manager-gateway.js"
import { makeMcpOAuthFlows } from "./mcp-manager-oauth-flows.js"
import { makeMcpPluginOperations } from "./mcp-manager-plugins.js"
import { makeMcpReplicationOperations } from "./mcp-manager-replication.js"
import { makeMcpServerOperations } from "./mcp-manager-servers.js"
import type { McpManager, McpManagerConfig } from "./mcp-manager-types.js"
import { makeMcpOAuthRuntime } from "./mcp-oauth.js"
import { reportBackgroundFailure, run } from "./mcp-support.js"
import { makeConnectUpstream } from "./mcp-upstream.js"

export { automationSkillPath } from "./mcp-automation-builtins.js"
export type { ToolGatewayConfig } from "./mcp-gateway.js"
export type { ExecutionJobFinished, ExecutionJobs } from "./mcp-gateway-jobs.js"
export type { ExecutionTimers } from "./mcp-gateway-execution.js"
export type { PackagedSkill, SkillSource } from "./mcp-gateway-skills.js"
export { NodeStreamableHttpTransport } from "./mcp-http-transport.js"
export type { McpOAuthClock } from "./mcp-oauth-clock.js"

export const makeMcpManager = (config: McpManagerConfig): McpManager => {
  const core = makeMcpManagerCore(config)
  const connectUpstream = makeConnectUpstream(core, (id) => oauthRuntime.upstreamAuthorization(id))
  const jobs = makeExecutionJobs({
    dataDir: config.dataDir,
    timers: config.executionTimers ?? systemExecutionTimers
  })

  const {
    allTools,
    composerSkillsFor,
    createGatewayConnection,
    finishRemoteBrowserTurn,
    gatewayRuntime,
    invokeRemoteGatewayCall,
    refreshGatewayInventories
  } = makeMcpGateway({
    appViews: core.appViews,
    automationProviders: core.automationProviders,
    browserSetupBroker: core.browserSetupBroker,
    codeExecutor: core.codeExecutor,
    config,
    connectUpstream,
    gateways: core.gateways,
    isSuppressed: (name) => core.state.locallySuppressed.has(name),
    jobs,
    record: core.record,
    selfMachine: core.selfMachine,
    turnClientId: (sessionId) => core.turnClientIds.get(sessionId)
  })

  const unsubscribeSkills = config.skillSource?.subscribe(() => {
    /* v8 ignore next 2 */
    void refreshGatewayInventories().catch((cause: unknown) =>
      reportBackgroundFailure("Skill inventory refresh failed", cause)
    )
  })

  const oauthRuntime = makeMcpOAuthRuntime({
    callbackUrl: core.callbackUrl,
    cancelOAuthRetry: core.cancelOAuthRetry,
    clock: core.oauthClock,
    closeConnection: core.closeConnection,
    connectUpstream,
    hasConnection: (id) => core.connections.has(id),
    oauthRetries: core.oauthRetries,
    onCredentialChanged: core.emitCredentialsRotated,
    record: core.record,
    refreshGatewayInventories,
    replaceSecrets: core.replaceSecrets,
    saveRecord: core.saveRecord,
    secrets: core.secrets,
    selfServerId: core.selfServerId,
    vault: config.oauthVault
  })

  const serverOperations = makeMcpServerOperations(core, {
    allTools,
    connectUpstream,
    refreshGatewayInventories
  })
  const manager: McpManager = {
    composerSkills: composerSkillsFor,
    detectAuth: detectMcpAuth,
    ...serverOperations,
    ...makeMcpReplicationOperations(core, oauthRuntime),
    ...makeMcpOAuthFlows(core, oauthRuntime),
    ...makeMcpGatewayOperations(core, {
      createGatewayConnection,
      finishRemoteBrowserTurn,
      gatewayRuntime,
      invokeRemoteGatewayCall,
      jobs,
      unsubscribeSkills
    }),
    ...makeMcpBrowserOperations(core),
    ...makeMcpPluginOperations(core, connectUpstream),
    jobs,
    iconSources: async (id) => {
      const server = await core.record(id).catch(() => undefined)
      if (server === undefined) return undefined
      const info = core.connections.get(id)?.serverInfo
      return {
        ...(server.url === undefined ? {} : { url: server.url }),
        ...(server.catalogId === undefined ? {} : { catalogId: server.catalogId }),
        ...(info?.icons === undefined ? {} : { icons: info.icons }),
        ...(info?.websiteUrl === undefined ? {} : { websiteUrl: info.websiteUrl })
      }
    }
  }

  void run(config.db.listMcpServers)
    .then((servers) => {
      for (const server of servers) {
        const oauth = core.secrets(server).oauth
        if (oauth?.tokens === undefined && (oauth?.credential ?? undefined) === undefined) continue
        void oauthRuntime.migrateLegacyGrant(server.id)
        if (server.enabled && server.connectionState === "needsAuthorization") {
          /* v8 ignore next */
          void serverOperations.connect(server.id).catch(() => undefined)
        }
      }
    })
    /* v8 ignore start */
    .catch((cause: unknown) => reportBackgroundFailure("MCP OAuth restoration failed", cause))
  /* v8 ignore stop */

  return manager
}
