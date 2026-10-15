import type { CodevisorExecutionFile, CodevisorExecutionIcon } from "@codevisor/api"
import type { AutomationToolProvider, ComputerUseApp } from "@codevisor/automation"
import type { McpServerRecord } from "@codevisor/db"

import {
  appIcon,
  executionCallIcon,
  executionFiles,
  humanizeToolName,
  siteIcon,
  type ExecutionRecorder
} from "./mcp-gateway-execution.js"
import type { SandboxArtifactCollector } from "./mcp-sandbox-results.js"
import type { UpstreamConnection } from "./mcp-support.js"

const isBuiltin = (icon: CodevisorExecutionIcon | undefined, id: "browser" | "computer"): boolean =>
  icon?.kind === "builtin" && icon.id === id

export type StepOutcome =
  | { readonly ok: true; readonly value: unknown }
  | { readonly ok: false; readonly error: string }

export const makeExecutionSteps = (deps: {
  readonly recorder: ExecutionRecorder
  readonly collector: SandboxArtifactCollector
  readonly record: (id: string) => Promise<Pick<McpServerRecord, "url">>
  readonly automationProviders: ReadonlyMap<string, AutomationToolProvider>
  readonly connectUpstream: (id: string) => Promise<Pick<UpstreamConnection, "tools">>
}) => {
  const { recorder, collector } = deps
  let browserSite: CodevisorExecutionIcon | undefined
  let computerApp: CodevisorExecutionIcon | undefined
  const surface = (touched: CodevisorExecutionIcon | undefined) =>
    isBuiltin(touched, "browser")
      ? browserSite
      : isBuiltin(touched, "computer")
        ? computerApp
        : undefined
  const storedFiles: Array<CodevisorExecutionFile> = []
  const artifacts: SandboxArtifactCollector = {
    ...collector,
    persistence: {
      persist: async (artifact) => {
        const stored = await collector.persistence?.persist(artifact)
        if (stored !== undefined)
          storedFiles.push({ fileId: stored.fileId, name: stored.name, mimeType: stored.mimeType })
        return stored
      }
    }
  }

  const serverHost = async (serverId: string): Promise<string | undefined> => {
    const server = await deps.record(serverId)
    return server.url === undefined ? undefined : new URL(server.url).hostname
  }

  const toolTitle = async (path: string, local: boolean): Promise<string | undefined> => {
    const separator = path.indexOf(".")
    if (separator <= 0) return undefined
    const serverId = path.slice(0, separator)
    const name = path.slice(separator + 1)
    const declared = !local
      ? []
      : (deps.automationProviders.get(serverId)?.tools ??
        (await deps.connectUpstream(serverId).then(
          (connection) => connection.tools,
          () => []
        )))
    const tool = declared.find((candidate) => candidate.name === name)
    return tool?.title ?? tool?.annotations?.title ?? humanizeToolName(name === "js" ? path : name)
  }

  const callFiles = (value: unknown): Array<CodevisorExecutionFile> => {
    const files = [...storedFiles.splice(0), ...executionFiles(value)]
    return files.filter(
      (file, index) => files.findIndex((other) => other.fileId === file.fileId) === index
    )
  }

  return {
    artifacts,
    onBrowserPage: (url: string): void => {
      const site = siteIcon(url)
      if (site === undefined) return
      browserSite = site
      recorder.touch(site)
    },
    onComputerApp: (app: ComputerUseApp): void => {
      computerApp = appIcon(app)
      recorder.touch(computerApp)
    },
    begin: async (
      path: string,
      call: { readonly internal: boolean; readonly local: boolean; readonly machine?: string }
    ): Promise<(outcome: StepOutcome) => Promise<void>> => {
      if (call.internal) return async () => {}
      const started = performance.now()
      const touched = await executionCallIcon(path, serverHost)
      if (touched !== undefined) recorder.touch(surface(touched) ?? touched)
      return async (outcome) => {
        const title = await toolTitle(path, call.local)
        const icon = surface(touched) ?? touched
        const files = callFiles(outcome.ok ? outcome.value : undefined)
        recorder.call({
          path,
          ...(title === undefined ? {} : { title }),
          ...(icon === undefined ? {} : { icon }),
          ...(call.machine === undefined ? {} : { machine: call.machine }),
          ok: outcome.ok,
          ms: Math.round(performance.now() - started),
          ...(outcome.ok ? {} : { error: outcome.error }),
          ...(files.length === 0 ? {} : { files })
        })
      }
    }
  }
}
