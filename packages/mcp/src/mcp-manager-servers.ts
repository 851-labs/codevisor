import { randomUUID } from "node:crypto"
import { detectMcpAuth } from "./mcp-auth-detection.js"
import type { CatalogServer, makeMcpGateway } from "./mcp-gateway.js"
import type { McpManagerCore } from "./mcp-manager-core.js"
import type { McpManager } from "./mcp-manager-types.js"
import { encryptSecrets, type StoredOAuth, type StoredSecrets } from "./mcp-secret-store.js"
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
  | "tools"
  | "update"
>

const mergedSecretRecord = (
  current: Readonly<Record<string, string>> | undefined,
  updates: Readonly<Record<string, string>> | undefined,
  removals: ReadonlyArray<string> | undefined
): Record<string, string> | undefined => {
  const next = { ...current, ...updates }
  for (const name of removals ?? []) delete next[name]
  return Object.keys(next).length === 0 ? undefined : next
}

/// The managed-server lifecycle: create, update, remove, connect, and the
/// project/session resolution views over the persisted records.
export const makeMcpServerOperations = (
  core: McpManagerCore,
  deps: McpServerOperationDeps
): McpServerOperations => {
  const {
    automationProviders,
    browserProvider,
    builtinProviderState,
    builtinsReady,
    closeConnection,
    computerProvider,
    config,
    connections,
    key,
    publicServer,
    record,
    refreshBuiltinProviderStates,
    refreshTimers,
    saveRecord,
    secrets,
    state,
    syncManagedAutomationSkillsFromDb
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
    const authType =
      request.transport === "stdio"
        ? "none"
        : (request.authType ?? (await detectMcpAuth(requireHttpUrl(request.url))).authType)
    const id = randomUUID()
    const oauthState = `${id}.${randomUUID()}`
    const oauth: StoredOAuth = {
      state: oauthState,
      ...(request.oauthClientId === undefined ? {} : { configuredClientId: request.oauthClientId }),
      ...(request.oauthClientSecret === undefined
        ? {}
        : { configuredClientSecret: request.oauthClientSecret })
    }
    const stored: StoredSecrets = {
      ...(request.env === undefined ? {} : { env: request.env }),
      ...(request.headers === undefined ? {} : { headers: request.headers }),
      // "" is the editor's untouched field, not a credential.
      ...(request.bearerToken === undefined || request.bearerToken === ""
        ? {}
        : { bearerToken: request.bearerToken }),
      ...(authType !== "oauth"
        ? {}
        : {
            oauth
          })
    }
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
        enabled: authType === "oauth" ? false : (request.enabled ?? true),
        authType,
        ...(request.oauthScope === undefined ? {} : { oauthScope: request.oauthScope }),
        connectionState: authType === "oauth" ? "needsAuthorization" : "disconnected",
        toolCount: 0,
        secretCipher: encryptSecrets(key, stored)
      })
    )
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
      const unsupported = Object.keys(request).filter((key) => key !== "enabled")
      if (unsupported.length > 0) throw new Error(`${current.name} is managed by Codevisor`)
      const enabled = request.enabled ?? current.enabled
      const state = builtinProviderState(current.id as "browser" | "computer", enabled)
      const saved = await saveRecord(current, {
        enabled,
        connectionState: state.connectionState,
        ...(state.detail === undefined ? {} : { detail: state.detail })
      })
      const provider = automationProviders.get(saved.id)!
      if (!saved.enabled) {
        await provider.close()
      } else if (saved.id === "browser" && state.connectionState === "needsSetup") {
        // Browser downloads can take several minutes. Keep the toggle
        // responsive and let the settings view observe setup progress.
        void connect(saved.id).catch(() => undefined)
      } else if (state.connectionState !== "unavailable") {
        await connect(saved.id).catch(() => undefined)
      }
      await syncManagedAutomationSkillsFromDb()
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
    await closeConnection(id)
    const updatedOauth: StoredOAuth | undefined =
      request.oauthClientId === undefined && request.oauthClientSecret === undefined
        ? currentSecrets.oauth
        : {
            ...currentSecrets.oauth,
            ...(request.oauthClientId === undefined
              ? {}
              : { configuredClientId: request.oauthClientId }),
            ...(request.oauthClientSecret === undefined
              ? {}
              : { configuredClientSecret: request.oauthClientSecret })
          }
    const nextSecrets: StoredSecrets = {
      ...currentSecrets,
      ...(request.env === undefined && request.removeEnv === undefined
        ? {}
        : { env: mergedSecretRecord(currentSecrets.env, request.env, request.removeEnv) }),
      ...(request.headers === undefined && request.removeHeaders === undefined
        ? {}
        : {
            headers: mergedSecretRecord(
              currentSecrets.headers,
              request.headers,
              request.removeHeaders
            )
          }),
      ...(request.bearerToken === undefined ? {} : { bearerToken: request.bearerToken }),
      ...(updatedOauth === undefined ? {} : { oauth: updatedOauth })
    }
    const nextAuthType = request.authType ?? current.authType
    const oauthIsAuthorized = nextSecrets.oauth?.tokens !== undefined
    const enabled =
      nextAuthType === "oauth" && !oauthIsAuthorized ? false : (request.enabled ?? current.enabled)
    const saved = await saveRecord(current, {
      name: request.name ?? current.name,
      url,
      command,
      args: request.args ?? current.args,
      enabled,
      authType: nextAuthType,
      oauthScope: request.oauthScope ?? current.oauthScope,
      connectionState:
        nextAuthType === "oauth" && !oauthIsAuthorized ? "needsAuthorization" : "disconnected",
      toolCount: 0,
      detail: undefined,
      secretCipher: encryptSecrets(key, nextSecrets)
    })
    /* v8 ignore next -- authorized OAuth reconnects are handled by live completion validation. */
    if (saved.enabled && (saved.authType !== "oauth" || oauthIsAuthorized)) {
      await connect(id).catch(() => undefined)
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
    // Machine-disabling a built-in (Computer Use) must also retract its
    // managed skill; re-derive from the store now that suppression changed.
    await syncManagedAutomationSkillsFromDb()
  }

  const remove: McpManager["remove"] = async (id) => {
    await builtinsReady
    const current = await record(id)
    if (!current.canRemove) throw new Error(`${current.name} cannot be removed`)
    await closeConnection(id)
    const timer = refreshTimers.get(id)
    /* v8 ignore next -- timers only exist for the live OAuth refresh adapter. */
    if (timer !== undefined) clearTimeout(timer)
    refreshTimers.delete(id)
    await run(config.db.deleteMcpServer(id))
    await refreshGatewayInventories()
  }

  const tools: McpManager["tools"] = async (id) => {
    const selected: CatalogServer | undefined =
      id === undefined
        ? undefined
        : id === "codevisor"
          ? { id: "codevisor", name: "Codevisor" }
          : await record(id)
    const pairs =
      id === undefined
        ? await allTools()
        : (automationProviders.get(id)?.tools ?? (await connectUpstream(id)).tools).map((tool) => ({
            server: selected!,
            tool
          }))
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
    tools,
    update
  }
}
