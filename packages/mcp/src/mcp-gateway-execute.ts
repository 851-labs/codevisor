import { withRunningThoughtLevel } from "@codevisor/agent-runtime"
import type { ExecutionJob } from "@codevisor/api"
import type {
  AutomationToolProvider,
  CodeExecutionResult,
  CodeExecutor,
  CodeToolCall,
  CodeToolInvoker
} from "@codevisor/automation"
import type { McpServerRecord } from "@codevisor/db"
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"

import { gatewayToolError, type makeGatewayDispatch } from "./mcp-gateway-dispatch.js"
import {
  EXECUTE_DEFAULT_TIMEOUT_MS,
  executionArgsHash,
  makeExecutionRecorder,
  type ExecutionRecorder
} from "./mcp-gateway-execution.js"
import type { ExecutionJobs, ExecutionRun, RunOutcome } from "./mcp-gateway-jobs.js"
import { makeExecutionSteps } from "./mcp-gateway-steps.js"
import type { GatewayRuntime } from "./mcp-gateway.js"
import { isRecord } from "./mcp-guards.js"
import type { GatewayCallContext, GatewayOrigin, McpManagerConfig } from "./mcp-manager-types.js"
import { sandboxOutputContent } from "./mcp-sandbox-results.js"
import { run, type UpstreamConnection } from "./mcp-support.js"

export interface ExecuteArgs {
  readonly code: string
  readonly description: string
  readonly timeout_ms?: number | undefined
}

type GatewayDispatch = ReturnType<typeof makeGatewayDispatch>

export interface ExecuteToolDeps {
  readonly automationProviders: ReadonlyMap<string, AutomationToolProvider>
  readonly codeExecutor: CodeExecutor
  readonly config: McpManagerConfig
  readonly connectUpstream: (id: string) => Promise<UpstreamConnection>
  readonly dispatch: Pick<
    GatewayDispatch,
    "invokeGatewayTool" | "invokeOnMachine" | "newArtifactCollector"
  >
  readonly jobs: ExecutionJobs
  readonly openBrowserSessionTabs: (sessionId: string, projectId?: string) => Promise<string>
  readonly record: (id: string) => Promise<McpServerRecord>
  readonly selfMachine: { readonly id: string; readonly name: string }
  readonly turnClientId: (sessionId: string) => string | undefined
}

export const stillRunningText = (job: ExecutionJob): string =>
  JSON.stringify({
    status: "running",
    jobId: job.jobId,
    elapsedMs: job.elapsedMs,
    running: job.running,
    ...(job.progress === undefined ? {} : { progress: job.progress }),
    logs: job.logs,
    outputPath: job.outputPath,
    next:
      `This call is still running in the background as job ${job.jobId}; nothing was cancelled. ` +
      `When it finishes, Codevisor sends you a hidden <codevisor-event type="execution.job_finished"> ` +
      "message with its result, so you can end your turn instead of waiting. To check sooner, run " +
      `execute with machines.current.tools.codevisor.jobs.wait({ jobId: "${job.jobId}" }) (it waits ` +
      `within that call's budget) or machines.current.tools.codevisor.jobs.get({ jobId: "${job.jobId}" }); ` +
      `machines.current.tools.codevisor.jobs.cancel({ jobId: "${job.jobId}" }) stops it. Live output is appended to outputPath.`
  })

export const makeExecuteHandler =
  (deps: ExecuteToolDeps) =>
  (runtime: GatewayRuntime) =>
  async (args: ExecuteArgs, extra: { readonly signal: AbortSignal }): Promise<CallToolResult> => {
    const recorder = executionRecorder(runtime, args)
    const execution = deps.jobs.begin({
      sessionId: runtime.sessionId,
      description: args.description,
      timeoutMs: args.timeout_ms ?? EXECUTE_DEFAULT_TIMEOUT_MS,
      requestSignal: extra.signal
    })
    const call = makeExecuteCall(deps, runtime, recorder, execution)
    const outcome = await execution.outcome(call.start(args.code))
    if (outcome.kind === "detached") return detachedResult(recorder, outcome.job)

    return call.finish(outcome)
  }

const executionRecorder = (runtime: GatewayRuntime, args: ExecuteArgs): ExecutionRecorder =>
  makeExecutionRecorder({
    sink: runtime.sink,
    sessionId: runtime.sessionId,
    argsHash: executionArgsHash({
      code: args.code,
      description: args.description,
      ...(args.timeout_ms === undefined ? {} : { timeout_ms: args.timeout_ms })
    }),
    description: args.description
  })

const detachedResult = async (
  recorder: ExecutionRecorder,
  job: ExecutionJob
): Promise<CallToolResult> => {
  recorder.status(`Still running in the background as job ${job.jobId}`)
  await recorder.finish()
  return { content: [{ type: "text", text: stillRunningText(job) }] }
}

const makeExecuteCall = (
  deps: ExecuteToolDeps,
  runtime: GatewayRuntime,
  recorder: ExecutionRecorder,
  execution: ExecutionRun
) => {
  const { sessionId, projectId } = runtime
  const steps = makeExecutionSteps({
    recorder,
    collector: deps.dispatch.newArtifactCollector(),
    record: deps.record,
    automationProviders: deps.automationProviders,
    connectUpstream: deps.connectUpstream
  })
  const clientId = deps.turnClientId(sessionId)
  const origin = callOrigin(deps, sessionId, clientId)
  const callContext: GatewayCallContext = {
    sessionId,
    ...(projectId === undefined ? {} : { projectId }),
    origin
  }
  const remoteOrigin = titledOrigin(deps, origin)
  let usedBrowser = false

  const invokeLocally = (path: string, args: unknown): Promise<unknown> =>
    deps.dispatch.invokeGatewayTool(callContext, path, args, {
      artifacts: steps.artifacts,
      signal: execution.signal,
      deadline: execution.deadline(),
      onBrowser: () => {
        usedBrowser = true
      },
      onBrowserPage: steps.onBrowserPage,
      onComputerApp: steps.onComputerApp
    })

  const invoke = async ({ path, args, target }: CodeToolCall): Promise<unknown> => {
    const machine = remoteTarget(deps, target)
    const settle = await steps.begin(path, {
      internal: target?.internal === true,
      local: machine === undefined,
      ...(machine === undefined ? {} : { machine: machine.machineName ?? machine.machine })
    })
    const untrack = execution.track(path)
    try {
      let value: unknown
      if (machine === undefined) {
        value = await invokeLocally(path, args)
      } else {
        value = await deps.dispatch.invokeOnMachine(
          machine,
          path,
          await withCallerDefaults(deps, sessionId, path, args),
          await remoteOrigin(),
          execution.signal
        )
      }
      await settle({ ok: true, value })
      return value
    } catch (cause) {
      const error = gatewayToolError(cause)
      await settle({ ok: false, error: error.message })
      throw error
    } finally {
      untrack()
    }
  }

  const invoker: CodeToolInvoker = { invoke }

  const start = (code: string): Promise<CodeExecutionResult> =>
    deps.codeExecutor.execute(code, invoker, {
      signal: execution.signal,
      onStatus: (text) => {
        recorder.status(text)
        execution.status(text)
      },
      onLog: execution.log,
      context: {
        machine: deps.selfMachine,
        ...(clientId === undefined ? {} : { originClientId: clientId })
      }
    })

  const failure = async (error: string): Promise<CallToolResult> => {
    await recorder.finish(error)
    let openTabs = ""
    if (usedBrowser) {
      openTabs = await deps.openBrowserSessionTabs(sessionId, projectId).catch(() => "")
    }
    return { isError: true, content: [{ type: "text", text: `${error}${openTabs}` }] }
  }

  const finish = async (
    outcome: Extract<RunOutcome, { kind: "finished" }>
  ): Promise<CallToolResult> => {
    const error = outcome.stopped ?? outcome.result.error
    if (error !== undefined) return failure(error)

    await recorder.finish()
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({ result: outcome.result.result, logs: outcome.result.logs })
        },
        ...sandboxOutputContent(outcome.result.output),
        ...steps.artifacts.content
      ]
    }
  }

  return { start, finish }
}

const callOrigin = (
  deps: ExecuteToolDeps,
  sessionId: string,
  clientId: string | undefined
): GatewayOrigin => ({
  machineId: deps.selfMachine.id,
  machineName: deps.selfMachine.name,
  sessionId,
  ...(clientId === undefined ? {} : { clientId })
})

const titledOrigin = (deps: ExecuteToolDeps, origin: GatewayOrigin) => {
  let titled: Promise<GatewayOrigin> | undefined
  return (): Promise<GatewayOrigin> => {
    titled ??= describedOrigin(deps, origin)
    return titled
  }
}

const describedOrigin = async (
  deps: ExecuteToolDeps,
  origin: GatewayOrigin
): Promise<GatewayOrigin> => {
  const sessionId = origin.sessionId!
  const session = await run(deps.config.db.getSessionSummary(sessionId)).catch(() => undefined)
  const bot = await run(deps.config.db.findBotLinkForSession(sessionId)).catch(() => undefined)
  return {
    ...origin,
    ...(session === undefined ? {} : { sessionTitle: session.title }),
    ...bot
  }
}

const remoteAgentStartPath = "codevisor.agents.start"

const withCallerDefaults = async (
  deps: ExecuteToolDeps,
  sessionId: string,
  path: string,
  args: unknown
): Promise<unknown> => {
  if (path !== remoteAgentStartPath || !isRecord(args) || "callerDefaults" in args) return args
  const caller = await run(deps.config.db.getSessionSummary(sessionId)).catch(() => undefined)
  if (caller === undefined) return args
  const runtime = await run(deps.config.db.getSessionRuntimeState(sessionId))
  const configSelections = withRunningThoughtLevel(caller.configSelections, runtime)
  return {
    ...args,
    callerDefaults: {
      harness: caller.harnessId,
      ...(configSelections === undefined ? {} : { configSelections })
    }
  }
}

const remoteTarget = (
  deps: ExecuteToolDeps,
  target: CodeToolCall["target"]
): { readonly machine: string; readonly machineName?: string } | undefined => {
  if (target?.machine === undefined || target.machine === deps.selfMachine.id) return undefined
  return {
    machine: target.machine,
    ...(target.machineName === undefined ? {} : { machineName: target.machineName })
  }
}
