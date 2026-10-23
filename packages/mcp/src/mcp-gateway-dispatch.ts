import { realpathSync, statSync } from "node:fs"
import { isAbsolute, relative, resolve } from "node:path"

import { isFleetPath, remoteSessionKey } from "@codevisor/api"
import type {
  AutomationProviderContext,
  AutomationToolProvider,
  BrowserSetupBroker,
  ComputerUseApp
} from "@codevisor/automation"
import { browserResultPageUrl, CodeExecutionToolError } from "@codevisor/automation"
import type { McpServerRecord } from "@codevisor/db"
import { type CallToolResult, CallToolResultSchema } from "@modelcontextprotocol/sdk/types.js"

import type { makeGatewayCatalog } from "./mcp-gateway-catalog.js"
import { isRecord } from "./mcp-guards.js"
import type {
  GatewayCallContext,
  GatewayOrigin,
  McpManagerConfig,
  RemoteGatewayCallOptions
} from "./mcp-manager-types.js"
import { invokeGatewayPluginTool } from "./mcp-plugin-tools.js"
import type { makeRecordingPublisher } from "./mcp-recording-artifacts.js"
import {
  type SandboxArtifactCollector,
  type SandboxArtifactPersistence,
  sandboxSuccessfulToolResult
} from "./mcp-sandbox-results.js"
import { errorMessage, run, type UpstreamConnection } from "./mcp-support.js"

export interface GatewayInvokeOptions {
  readonly artifacts?: SandboxArtifactCollector
  readonly signal?: AbortSignal
  readonly deadline?: number
  readonly botLink?: string
  readonly onBrowser?: () => void
  readonly onBrowserPage?: (url: string) => void
  readonly onComputerApp?: (app: ComputerUseApp) => void
}

export const gatewayToolError = (cause: unknown): CodeExecutionToolError => {
  if (cause instanceof CodeExecutionToolError) return cause
  const { code, details }: Record<string, unknown> = isRecord(cause) ? cause : {}
  return new CodeExecutionToolError(errorMessage(cause), {
    ...(typeof code === "string" ? { code } : {}),
    ...(isRecord(details) ? { details } : {})
  })
}

type GatewayCatalog = ReturnType<typeof makeGatewayCatalog>

export interface GatewayDispatchDeps {
  readonly artifactPersistence: SandboxArtifactPersistence
  readonly automationProviders: Map<string, AutomationToolProvider>
  readonly browserSetupBroker: BrowserSetupBroker
  readonly catalog: Pick<
    GatewayCatalog,
    "describeCatalogPath" | "gatewayServerAllowed" | "searchCatalog"
  >
  readonly config: McpManagerConfig
  readonly connectUpstream: (id: string) => Promise<UpstreamConnection>
  readonly publishRecording: ReturnType<typeof makeRecordingPublisher>
  readonly record: (id: string) => Promise<McpServerRecord>
  readonly selfMachine: { readonly id: string; readonly name: string }
}

interface AutomationCallContext {
  readonly sessionId: string
  readonly projectId?: string | undefined
  readonly signal?: AbortSignal | undefined
  readonly deadline?: number | undefined
  readonly botLink?: string | undefined
}

interface BrowserCaller {
  readonly provider: AutomationToolProvider
  readonly context: AutomationCallContext
  readonly collector: SandboxArtifactCollector | undefined
  readonly remote: GatewayOrigin | undefined
  readonly onPage: ((url: string) => void) | undefined
}

const reportBrowserPage = (
  result: CallToolResult,
  onPage: ((url: string) => void) | undefined
): void => {
  const pageUrl = browserResultPageUrl(result)
  if (pageUrl !== undefined) onPage?.(pageUrl)
}

const assertAutomationToolArguments = (
  provider: AutomationToolProvider,
  toolName: string,
  args: Readonly<Record<string, unknown>>
): void => {
  if (provider.id !== "browser" && provider.id !== "computer" && provider.id !== "codevisor") {
    throw new Error(`Unknown automation provider: ${String(provider.id)}`)
  }
  const definition = provider.tools.find((candidate) => candidate.name === toolName)
  if (definition === undefined) throw new Error(`Unknown ${provider.id} tool: ${toolName}`)
  const declared = definition.inputSchema.properties
  const properties = isRecord(declared) ? declared : {}
  const unknownArguments = Object.keys(args).filter((key) => !(key in properties))
  if (unknownArguments.length > 0) {
    throw new Error(
      `${provider.id}.${toolName} does not accept ${unknownArguments.map((key) => `\`${key}\``).join(", ")}`
    )
  }
}

const workspaceUploadPaths = (
  args: Readonly<Record<string, unknown>>,
  workspaceRoot: string,
  toolName: string
): Array<string> => {
  const paths = Array.isArray(args.paths) ? args.paths : []
  if (paths.length === 0 || !paths.every((path) => typeof path === "string")) {
    throw new Error(`${toolName} requires one or more workspace file paths`)
  }
  return paths.map((path) => {
    const candidate = realpathSync(isAbsolute(path) ? path : resolve(workspaceRoot, path))
    const withinWorkspace = relative(workspaceRoot, candidate)
    if (withinWorkspace.startsWith("..") || isAbsolute(withinWorkspace)) {
      throw new Error("Browser Use can only upload files from the current workspace")
    }
    if (!statSync(candidate).isFile()) throw new Error(`Upload path is not a file: ${path}`)
    return candidate
  })
}

export const makeGatewayDispatch = (deps: GatewayDispatchDeps) => {
  const {
    artifactPersistence,
    automationProviders,
    browserSetupBroker,
    catalog: { describeCatalogPath, gatewayServerAllowed, searchCatalog },
    config,
    connectUpstream,
    publishRecording,
    record,
    selfMachine
  } = deps

  const invokePluginTool = async (
    sessionId: string,
    name: string,
    args: Readonly<Record<string, unknown>>
  ): Promise<unknown> => {
    const session = await run(config.db.getSessionSummary(sessionId))
    return invokeGatewayPluginTool(
      config.pluginTools,
      name,
      args,
      session.cwd === undefined ? {} : { cwd: session.cwd }
    )
  }

  const computerUsePermissionPrompt = (
    context: {
      readonly sessionId: string
      readonly signal?: AbortSignal | undefined
      readonly deadline?: number | undefined
    },
    remote: GatewayOrigin | undefined
  ): { readonly requestPermissions?: () => Promise<boolean> } => {
    if (remote !== undefined) return {}

    return {
      requestPermissions: () =>
        browserSetupBroker.requestComputerUsePermissions(context.sessionId, {
          signal: context.signal,
          deadline: context.deadline
        })
    }
  }

  const browserProviderContext = (caller: BrowserCaller): AutomationProviderContext => ({
    ...caller.context,
    invokeBrowser: (name: string, nested: Record<string, unknown>) =>
      invokeNestedBrowserTool(caller, name, nested)
  })

  const invokeNestedBrowserTool = async (
    caller: BrowserCaller,
    name: string,
    nested: Record<string, unknown>
  ): Promise<unknown> => {
    const { provider, context, collector, remote, onPage } = caller
    const result = await invokeAutomationProvider(
      provider,
      context,
      name,
      nested,
      collector,
      remote,
      onPage
    )
    reportBrowserPage(result, onPage)
    return sandboxSuccessfulToolResult(result, nestedBrowserCollector(collector), "browser." + name)
  }

  const nestedBrowserCollector = (
    collector: SandboxArtifactCollector | undefined
  ): SandboxArtifactCollector =>
    collector ?? {
      content: [],
      maxItems: 20,
      maxBytes: 20_000_000,
      persistence: artifactPersistence
    }

  const invokeAutomationProvider = async (
    provider: AutomationToolProvider,
    context: AutomationCallContext,
    toolName: string,
    args: Readonly<Record<string, unknown>>,
    collector?: SandboxArtifactCollector,
    remote?: GatewayOrigin,
    onPage?: (url: string) => void,
    onApp?: (app: ComputerUseApp) => void
  ): Promise<CallToolResult> => {
    assertAutomationToolArguments(provider, toolName, args)
    let providerContext: AutomationProviderContext = context
    if (provider.id === "computer") {
      const callContext = { ...context }
      let agentLabel: string
      if (remote === undefined) {
        agentLabel = (await run(config.db.getSessionSummary(context.sessionId))).title
      } else {
        agentLabel = `${remote.sessionTitle ?? "Agent"} (from ${remote.machineName})`
      }
      providerContext = {
        ...callContext,
        agentLabel,
        publishRecording,
        ...computerUsePermissionPrompt(context, remote),
        ...(onApp === undefined ? {} : { onApp })
      }
    } else if (provider.id === "browser") {
      providerContext = browserProviderContext({ provider, context, collector, remote, onPage })
    }
    let safeArgs = args
    if (
      provider.id === "browser" &&
      (toolName === "upload_files" || toolName === "playwright.fileChooserSetFiles")
    ) {
      if (remote !== undefined) {
        throw new Error(
          `Browser Use uploads files from a workspace folder on this machine; a call from ${remote.machineName} has none`
        )
      }
      const session = await run(config.db.getSessionSummary(context.sessionId))
      if (session.cwd === undefined) throw new Error("This session has no workspace folder")
      const workspaceRoot = realpathSync(session.cwd)
      const resolvedPaths = workspaceUploadPaths(args, workspaceRoot, toolName)
      safeArgs = { ...args, paths: resolvedPaths }
    }
    if (provider.id === "browser") {
      await browserSetupBroker.ensureExtensionCurrent(
        context.sessionId,
        { toolName, args },
        { signal: context.signal, deadline: context.deadline }
      )
    }
    if (provider.id === "browser" && toolName === "request_extension_install") {
      const outcome = await browserSetupBroker.requestExtensionInstall(context.sessionId, {
        signal: context.signal,
        deadline: context.deadline
      })
      return { content: [{ type: "text", text: JSON.stringify(outcome) }] }
    }
    return provider.invoke(providerContext, toolName, safeArgs)
  }

  const newArtifactCollector = (): SandboxArtifactCollector => ({
    content: [],
    maxItems: 4,
    maxBytes: 10 * 1024 * 1024,
    persistence: artifactPersistence
  })

  const isRemoteOrigin = (origin: GatewayOrigin | undefined): origin is GatewayOrigin =>
    origin !== undefined && origin.machineId !== selfMachine.id

  const invokeGatewayTool = async (
    ctx: GatewayCallContext,
    path: string,
    args: unknown,
    options: GatewayInvokeOptions = {}
  ): Promise<unknown> => {
    const remote = isRemoteOrigin(ctx.origin) ? ctx.origin : undefined
    const scopeKey =
      remote === undefined ? ctx.sessionId : remoteSessionKey(remote.machineId, remote.sessionId)
    if (scopeKey === undefined) throw new Error("Gateway calls need a calling session")
    const sessionId = remote === undefined ? ctx.sessionId : undefined
    const projectId = remote === undefined ? ctx.projectId : undefined
    const artifacts = options.artifacts ?? newArtifactCollector()
    const input = isRecord(args) ? args : {}
    if (path === "search") {
      return searchCatalog(
        projectId,
        sessionId,
        typeof input.query === "string" ? input.query : "",
        typeof input.limit === "number" ? input.limit : 12
      )
    }
    if (path === "describe.tool") {
      if (typeof input.path !== "string") {
        throw new Error("tools.describe.tool expects { path: string }")
      }
      return describeCatalogPath(projectId, sessionId, input.path)
    }
    const separator = path.indexOf(".")
    if (separator <= 0 || separator === path.length - 1) {
      throw new Error(`Invalid tool path: ${path}`)
    }
    const serverId = path.slice(0, separator)
    const toolName = path.slice(separator + 1)
    if (serverId === "plugin") {
      if (sessionId !== undefined) return invokePluginTool(sessionId, toolName, input)
      try {
        return await invokeGatewayPluginTool(config.pluginTools, toolName, input, {})
      } catch (cause) {
        throw new Error(
          `plugin.${toolName} failed without a workspace folder (called from ${remote?.machineName ?? "another machine"}): ${errorMessage(cause)}`,
          { cause }
        )
      }
    }
    const installed = await record(serverId)
    const allowed = await gatewayServerAllowed(serverId, projectId, sessionId)
    if (!installed.enabled || !allowed) {
      throw new Error(`${installed.name} is disabled for this session`)
    }
    const provider = automationProviders.get(serverId)
    if (provider !== undefined) {
      if (serverId === "browser") options.onBrowser?.()
      const result = await invokeAutomationProvider(
        provider,
        {
          sessionId: scopeKey,
          ...(projectId === undefined ? {} : { projectId }),
          ...(options.signal === undefined ? {} : { signal: options.signal }),
          ...(options.deadline === undefined ? {} : { deadline: options.deadline }),
          ...(options.botLink === undefined ? {} : { botLink: options.botLink })
        },
        toolName,
        input,
        artifacts,
        remote,
        options.onBrowserPage,
        options.onComputerApp
      )
      const pageUrl = serverId === "browser" ? browserResultPageUrl(result) : undefined
      if (pageUrl !== undefined) options.onBrowserPage?.(pageUrl)
      return sandboxSuccessfulToolResult(result, artifacts, path)
    }
    const connection = await connectUpstream(serverId)
    const result = await connection.client.callTool(
      { name: toolName, arguments: input },
      undefined,
      options.signal === undefined ? undefined : { signal: options.signal }
    )
    return sandboxSuccessfulToolResult(CallToolResultSchema.parse(result), artifacts, path)
  }

  const invokeRemoteGatewayCall = (
    origin: GatewayOrigin,
    path: string,
    args: unknown,
    options: RemoteGatewayCallOptions = {}
  ): Promise<unknown> => invokeGatewayTool({ origin }, path, args, options)

  const remoteBrowserUse = new Map<string, Map<string, GatewayOrigin>>()

  const finishRemoteBrowserTurn = async (sessionId: string): Promise<void> => {
    const machines = remoteBrowserUse.get(sessionId)
    if (machines === undefined || config.remoteInvoker === undefined) return
    remoteBrowserUse.delete(sessionId)
    const invoke = config.remoteInvoker
    await Promise.all(
      [...machines].map(([machine, origin]) =>
        invoke(machine, "browser.finalizeTabs", { native: true }, origin).catch(() => undefined)
      )
    )
  }

  const invokeOnMachine = (
    target: { readonly machine: string; readonly machineName?: string },
    path: string,
    args: unknown,
    origin: GatewayOrigin,
    signal: AbortSignal | undefined
  ): Promise<unknown> => {
    const name = target.machineName ?? target.machine
    if (isFleetPath(path)) throw new CodeExecutionToolError(`Unknown tool: ${path}`)
    if (config.remoteInvoker === undefined) {
      throw new CodeExecutionToolError(`${name} is unreachable: this server has no machine link`, {
        code: "machine_unavailable",
        details: { machineId: target.machine, name, phase: "before-send" }
      })
    }
    if (path.startsWith("browser.") && origin.sessionId !== undefined) {
      const machines = remoteBrowserUse.get(origin.sessionId) ?? new Map<string, GatewayOrigin>()
      machines.set(target.machine, origin)
      remoteBrowserUse.set(origin.sessionId, machines)
    }
    return config.remoteInvoker(target.machine, path, args, origin, signal)
  }

  return {
    finishRemoteBrowserTurn,
    invokeAutomationProvider,
    invokeGatewayTool,
    invokeOnMachine,
    invokeRemoteGatewayCall,
    newArtifactCollector
  }
}
