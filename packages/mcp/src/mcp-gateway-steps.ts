import type { CodevisorExecutionFile, CodevisorExecutionIcon } from "@codevisor/api"
import type { AutomationToolProvider } from "@codevisor/automation"
import type { McpServerRecord } from "@codevisor/db"

import {
  executionCallIcon,
  executionFiles,
  humanizeToolName,
  siteIcon,
  type ExecutionRecorder
} from "./mcp-gateway-execution.js"
import type { SandboxArtifactCollector } from "./mcp-sandbox-results.js"
import type { UpstreamConnection } from "./mcp-support.js"

/// The steps of one `execute` run as the transcript shows them: what each
/// sandbox call touched (its icon), what it is called, and the files it
/// produced, recorded on the run's annotation as each call settles.

const isBrowser = (icon: CodevisorExecutionIcon | undefined): boolean =>
  icon?.kind === "builtin" && icon.id === "browser"

export type StepOutcome =
  | { readonly ok: true; readonly value: unknown }
  | { readonly ok: false; readonly error: string }

export const makeExecutionSteps = (deps: {
  readonly recorder: ExecutionRecorder
  readonly collector: SandboxArtifactCollector
  readonly record: (id: string) => Promise<McpServerRecord>
  readonly automationProviders: ReadonlyMap<string, AutomationToolProvider>
  readonly connectUpstream: (id: string) => Promise<UpstreamConnection>
}) => {
  const { recorder, collector } = deps
  // The site the session's tab is on, so later browser calls keep showing
  // it instead of flashing back to the bare browser.
  let browserSite: CodevisorExecutionIcon | undefined
  // Files the script stores (screenshots, exports) join the step that
  // stored them, even when the script stringifies their references.
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

  /// A step's label: the tool's declared title, else its name in words.
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
    /// A browser call left its tab on `url`.
    onBrowserPage: (url: string): void => {
      const site = siteIcon(url)
      if (site === undefined) return
      browserSite = site
      recorder.touch(site)
    },
    /// A call is starting: show what it touches, and return how to record
    /// it once it settles. The prelude's own lookups are never steps.
    begin: async (
      path: string,
      call: { readonly internal: boolean; readonly local: boolean; readonly machine?: string }
    ): Promise<(outcome: StepOutcome) => Promise<void>> => {
      if (call.internal) return async () => {}
      const started = performance.now()
      const touched = await executionCallIcon(path, serverHost)
      if (touched !== undefined)
        recorder.touch(isBrowser(touched) ? (browserSite ?? touched) : touched)
      return async (outcome) => {
        const title = await toolTitle(path, call.local)
        // A browser call is shown on the site it left its tab on.
        const icon = (isBrowser(touched) ? browserSite : undefined) ?? touched
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
