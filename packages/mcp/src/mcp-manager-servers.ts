import { randomUUID } from "node:crypto"

import type { McpAuthType, McpConnectionState } from "@codevisor/api"

import { detectMcpAuth } from "./mcp-auth-detection.js"
import { isBuiltinMcpId } from "./mcp-automation-builtins.js"
import type { CatalogServer, makeMcpGateway } from "./mcp-gateway.js"
import type { McpManagerCore } from "./mcp-manager-core.js"
import type { McpManager } from "./mcp-manager-types.js"
import { encryptSecrets } from "./mcp-secret-store.js"
import { connectionSecretsSignature, initialSecrets, updatedSecrets } from "./mcp-secret-update.js"
import { errorMessage, requireHttpUrl, run, validateRequest } from "./mcp-support.js"
import type { ConnectUpstream } from "./mcp-upstream.js"

type GatewayHandles = ReturnType<typeof makeMcpGateway>

export interface McpServerOperationDeps {
  readonly allTools: GatewayHandles["allTools"]
  readonly connectUpstream: ConnectUpstream
  readonly refreshGatewayInventories: GatewayHandles["refreshGatewayInventories"]
}

export type McpServerOperations = Pick<
  McpManager,
  | "connect"
  | "create"
  | "list"
  | "remove"
  | "resolved"
  | "setLocalSuppression"
  | "setProjectEnabled"
  | "setSessionEnabled"
  | "subscribeServersChanged"
  | "tools"
  | "update"
>

export const makeMcpServerOperations = (
  core: McpManagerCore,
  deps: McpServerOperationDeps
): McpServerOperations => {
  const {
    automationProviders,
    browserProvider,
    builtinProviderState,
    builtinsReady,
    changeListeners,
    closeConnection,
    computerProvider,
    config,
    connections,
    emitServerChanged,
    key,
    publicServer,
    record,
    cancelOAuthRetry,
    refreshBuiltinProviderStates,
    replaceSecrets,
    saveRecord,
    secrets,
    state
  } = core
  const { allTools, connectUpstream, refreshGatewayInventories } = deps

  const connect: McpManager["connect"] = async (id) => {
    await closeConnection(id)
    const provider = automationProviders.get(id)
    if (provider !== undefined) {
      try {
        if (id === "browser") await browserProvider.ensureSetup()
        if (id === "computer") await computerProvider.ensureSetup()
        const current = await record(id)
        return publicServer(
          await saveRecord(current, {
            connectionState: "connected",
            toolCount: provider.tools.length,
            detail: undefined
          })
        )
      } catch (cause) {
        await saveRecord(await record(id), {
          connectionState: id === "browser" ? "needsSetup" : "unavailable",
          toolCount: provider.tools.length,
          detail: errorMessage(cause)
        })
        throw cause
      }
    }
    await connectUpstream(id)
    return publicServer(await record(id))
  }

  const list: McpManager["list"] = async () => {
    await refreshBuiltinProviderStates()
    return (await run(config.db.listMcpServers)).map(publicServer)
  }

  const create: McpManager["create"] = async (request) => {
    await builtinsReady
    validateRequest(request)
    let authType: McpAuthType
    if (request.transport === "stdio") {
      authType = "none"
    } else {
      const requestedAuthType = request.authType
      if (requestedAuthType === undefined || requestedAuthType === null) {
        authType = (await detectMcpAuth(requireHttpUrl(request.url))).authType
      } else {
        authType = requestedAuthType
      }
    }
    const id = randomUUID()
    const stored = initialSecrets(request, authType, id)
    const url = request.transport === "http" ? requireHttpUrl(request.url) : undefined
    const command = request.transport === "stdio" ? request.command : undefined
    const saved = await run(
      config.db.saveMcpServer({
        id,
        name: request.name.trim(),
        kind: "managed",
        transport: request.transport,
        ...(url === undefined ? {} : { url }),
        ...(command === undefined ? {} : { command }),
        args: request.args ?? [],
        enabled: request.enabled ?? true,
        authType,
        ...(request.oauthScope === undefined ? {} : { oauthScope: request.oauthScope }),
        connectionState: authType === "oauth" ? "needsAuthorization" : "disconnected",
        toolCount: 0,
        secretCipher: encryptSecrets(key, stored)
      })
    )
    emitServerChanged(saved.id)
    if (saved.enabled && authType !== "oauth") {
      await connect(saved.id).catch(() => undefined)
    }
    await refreshGatewayInventories()
    return publicServer(await record(saved.id))
  }

  const update: McpManager["update"] = async (id, request) => {
    await builtinsReady
    const current = await record(id)
    if (!current.canEdit) {
      const unsupported = Object.keys(request).filter((field) => field !== "enabled")
      if (unsupported.length > 0 || !isBuiltinMcpId(current.id)) {
        throw new Error(`${current.name} is managed by Codevisor`)
      }
      const enabled = request.enabled ?? current.enabled
      const providerState = builtinProviderState(current.id, enabled)
      const saved = await saveRecord(current, {
        enabled,
        connectionState: providerState.connectionState,
        ...(providerState.detail === undefined ? {} : { detail: providerState.detail })
      })
      const provider = automationProviders.get(saved.id)!
      if (!saved.enabled) {
        await provider.close()
      } else if (saved.id === "browser" && providerState.connectionState === "needsSetup") {
        void connect(saved.id).catch(() => undefined)
      } else if (providerState.connectionState !== "unavailable") {
        await connect(saved.id).catch(() => undefined)
      }
      await refreshGatewayInventories()
      return publicServer(await record(saved.id))
    }
    const currentSecrets = secrets(current)
    const transport = current.transport
    const url = request.url ?? current.url
    const command = request.command ?? current.command
    validateRequest({
      transport,
      url,
      command,
      env: request.env,
      headers: request.headers,
      authType: request.authType,
      bearerToken: request.bearerToken,
      oauthScope: request.oauthScope,
      oauthClientId: request.oauthClientId,
      oauthClientSecret: request.oauthClientSecret
    })
    const nextSecrets = updatedSecrets(currentSecrets, request)
    const nextAuthType = request.authType ?? current.authType
    const oauthIsAuthorized =
      (nextSecrets.oauth?.credential ?? undefined) !== undefined ||
      nextSecrets.oauth?.tokens !== undefined
    const needsAuthorization = nextAuthType === "oauth" && !oauthIsAuthorized
    const enabled = request.enabled ?? current.enabled
    const args = request.args ?? current.args
    const oauthScope = request.oauthScope ?? current.oauthScope
    const definitionChanged =
      url !== current.url ||
      command !== current.command ||
      JSON.stringify(args) !== JSON.stringify(current.args) ||
      nextAuthType !== current.authType ||
      oauthScope !== current.oauthScope ||
      connectionSecretsSignature(nextSecrets) !== connectionSecretsSignature(currentSecrets)
    if (definitionChanged || !enabled) await closeConnection(id)
    const wasLive =
      current.connectionState === "connected" || current.connectionState === "connecting"
    let connectionState: McpConnectionState
    if (definitionChanged) {
      if (needsAuthorization) {
        connectionState = "needsAuthorization"
      } else {
        connectionState = "disconnected"
      }
    } else if (!enabled && wasLive) {
      connectionState = "disconnected"
    } else {
      connectionState = current.connectionState
    }
    const resetsState = definitionChanged || (!enabled && wasLive)
    if (JSON.stringify(nextSecrets) !== JSON.stringify(currentSecrets)) {
      await replaceSecrets(id, (latest) => updatedSecrets(latest, request))
    }
    const saved = await saveRecord(current, {
      name: request.name ?? current.name,
      url,
      command,
      args,
      enabled,
      authType: nextAuthType,
      oauthScope,
      connectionState,
      toolCount: resetsState ? 0 : current.toolCount,
      detail: resetsState ? undefined : current.detail
    })
    if (
      saved.enabled &&
      !needsAuthorization &&
      !connections.has(id) &&
      !state.locallySuppressed.has(saved.name)
    ) {
      void connect(id)
        .catch(() => undefined)
        .then(() => refreshGatewayInventories())
        .catch(() => undefined)
      return publicServer(await record(id))
    }
    await refreshGatewayInventories()
    return publicServer(await record(id))
  }

  const setLocalSuppression: McpManager["setLocalSuppression"] = async (names) => {
    await builtinsReady
    state.locallySuppressed = new Set(names)
    if (names.size > 0) {
      for (const server of await run(config.db.listMcpServers)) {
        if (!names.has(server.name)) continue
        if (connections.has(server.id)) {
          await closeConnection(server.id)
          await saveRecord(server, { connectionState: "disconnected", detail: undefined })
        }
      }
    }
    await refreshGatewayInventories()
  }

  const remove: McpManager["remove"] = async (id) => {
    await builtinsReady
    const current = await record(id)
    if (!current.canRemove) throw new Error(`${current.name} cannot be removed`)
    await closeConnection(id)
    cancelOAuthRetry(id)
    await run(config.db.deleteMcpServer(id))
    emitServerChanged(id)
    await refreshGatewayInventories()
  }

  const subscribeServersChanged: McpManager["subscribeServersChanged"] = (listener) => {
    changeListeners.add(listener)
    return () => {
      changeListeners.delete(listener)
    }
  }

  const tools: McpManager["tools"] = async (id) => {
    await builtinsReady
    let pairs: Awaited<ReturnType<typeof allTools>>
    if (id === undefined) {
      pairs = await allTools()
    } else {
      const selected: CatalogServer = await record(id)
      pairs = (automationProviders.get(id)?.tools ?? (await connectUpstream(id)).tools).map(
        (tool) => ({ server: selected, tool })
      )
    }
    return pairs.map(({ server, tool }) => ({
      serverId: server.id,
      serverName: server.name,
      name: tool.name,
      ...(tool.title === undefined ? {} : { title: tool.title }),
      ...(tool.description === undefined ? {} : { description: tool.description }),
      inputSchema: tool.inputSchema
    }))
  }

  const resolved: McpManager["resolved"] = async (projectId, sessionId) => {
    await builtinsReady
    return (await run(config.db.resolveMcpServers(projectId, sessionId)))
      .filter((server) => !state.locallySuppressed.has(server.name))
      .map(publicServer)
  }

  const setProjectEnabled: McpManager["setProjectEnabled"] = async (
    projectId,
    serverId,
    enabled
  ) => {
    await run(config.db.setProjectMcpEnabled(projectId, serverId, enabled))
    await refreshGatewayInventories()
    return resolved(projectId)
  }

  const setSessionEnabled: McpManager["setSessionEnabled"] = async (
    sessionId,
    serverId,
    enabled,
    projectId
  ) => {
    await run(config.db.setSessionMcpEnabled(sessionId, serverId, enabled))
    await refreshGatewayInventories()
    return resolved(projectId, sessionId)
  }

  return {
    connect,
    create,
    list,
    remove,
    resolved,
    setLocalSuppression,
    setProjectEnabled,
    setSessionEnabled,
    subscribeServersChanged,
    tools,
    update
  }
}
