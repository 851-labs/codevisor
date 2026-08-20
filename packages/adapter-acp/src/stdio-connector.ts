import * as acp from "@agentclientprotocol/sdk"
import { randomUUID } from "node:crypto"
import { spawn } from "node:child_process"
import type { ChildProcessWithoutNullStreams } from "node:child_process"
import { homedir } from "node:os"
import { Readable, Writable } from "node:stream"
import { Effect } from "effect"
import {
  adapterPromise,
  summarizeProcessFailure,
  type BackgroundTerminalIntegration,
  type QuestionAnswer,
  type RuntimeEvent
} from "@codevisor/agent-runtime"
import { makeAcpTerminalHost } from "./acp-terminals.js"
import { createClientApp, type ConfigureAcpClientApp } from "./client-app.js"
import { acpClientCapabilities, type AcpConnector } from "./connection.js"
import { isGenericConnectionClose } from "./internal.js"
import { isPiStartupInfoNotification, readPiSessionError } from "./pi.js"
import { runtimeEventFromNotification } from "./notifications.js"
import {
  acpPermissionOutcome,
  acpPermissionQuestion,
  type AcpMappedQuestion,
  type PendingAcpQuestion
} from "./questions.js"
import { sdkConnection, type AcpSdkConnectionCustomization } from "./sdk-connection.js"

export interface AcpStdioExtensionContext {
  readonly emit: (event: RuntimeEvent) => void
  readonly enqueueQuestion: <Response>(question: AcpMappedQuestion<Response>) => Promise<Response>
}

export interface AcpStdioExtension {
  readonly configureClientApp?: ConfigureAcpClientApp
  /// Replaces the default notification mapping for this connection. Returning
  /// an empty array deliberately consumes an update.
  readonly mapSessionNotification?: (
    notification: acp.SessionNotification
  ) => ReadonlyArray<RuntimeEvent>
  readonly sdkConnectionCustomization?: AcpSdkConnectionCustomization
}

export type AcpStdioExtensionFactory = (context: AcpStdioExtensionContext) => AcpStdioExtension

export interface StdioAcpConnectorOptions {
  readonly backgroundTerminals?: BackgroundTerminalIntegration
  readonly connectTimeoutMs?: number
  readonly terminalCommandMode?: "argv" | "shell"
  readonly extension?: AcpStdioExtensionFactory
}

/* v8 ignore start -- stdio ACP adapter is exercised by integration/packaging smoke tests. */
export const makeStdioAcpConnectorWithOptions = (
  options: StdioAcpConnectorOptions = {}
): AcpConnector => ({
  connect: (request, emit) =>
    adapterPromise("connect", async () => {
      const child = spawn(request.command, [...request.args], {
        cwd: request.cwd,
        // Some CLIs spawn worker descendants. A separate process group lets
        // close/timeout reliably terminate the whole ACP tree.
        detached: process.platform !== "win32",
        env: request.env,
        stdio: ["pipe", "pipe", "pipe"]
      })
      const terminate = processGroupTerminator(child)
      let closeConnection: ((error: Error) => void) | undefined
      const spawnFailure = new Promise<never>((_resolve, reject) => {
        child.once("error", (error) => {
          closeConnection?.(error)
          reject(error)
        })
      })
      spawnFailure.catch(() => undefined)
      const stderr = captureStderr(child)
      const pendingQuestions = new Map<string, PendingAcpQuestion>()
      const piStartupInfoBySession = new Map<string, string>()
      const safeEmit = (event: RuntimeEvent): void => {
        void emit(event).catch(() => undefined)
      }
      const terminals =
        options.backgroundTerminals === undefined
          ? undefined
          : makeAcpTerminalHost({
              commandMode: options.terminalCommandMode ?? "argv",
              emit,
              env: request.env,
              integration: options.backgroundTerminals
            })
      const emitQuestionResolved = (
        questionId: string,
        pending: PendingAcpQuestion,
        outcome: "answered" | "cancelled",
        answers: QuestionAnswer["answers"]
      ): void => {
        safeEmit({
          kind: "session.output",
          payload: {
            outcome,
            questionId,
            questions: pending.questions,
            sessionUpdate: "question_resolved",
            ...(answers === undefined ? {} : { answers })
          },
          subjectId: pending.sessionId
        })
      }
      const enqueueQuestion = <Response>(
        question: AcpMappedQuestion<Response>
      ): Promise<Response> => {
        const questionId = randomUUID()
        if (question.planDocument !== undefined) {
          safeEmit({
            kind: "session.output",
            payload: { markdown: question.planDocument, sessionUpdate: "plan_document" },
            subjectId: question.sessionId
          })
        }
        safeEmit({
          kind: "session.output",
          payload: {
            questionId,
            questions: question.questions,
            sessionUpdate: "question"
          },
          subjectId: question.sessionId
        })
        return new Promise<Response>((resolve) => {
          pendingQuestions.set(questionId, {
            cancelledResponse: question.cancelledResponse,
            questions: question.questions,
            resolve: (response) => resolve(response as Response),
            responseFor: question.responseFor,
            sessionId: question.sessionId
          })
        })
      }
      const extension = options.extension?.({ emit: safeEmit, enqueueQuestion })
      const connection = createClientApp(
        (notification) => {
          const startupInfo = piStartupInfoBySession.get(notification.sessionId)
          if (
            request.harnessId === "pi" &&
            startupInfo !== undefined &&
            isPiStartupInfoNotification(notification, startupInfo)
          ) {
            piStartupInfoBySession.delete(notification.sessionId)
            return
          }
          const events = extension?.mapSessionNotification?.(notification) ?? [
            runtimeEventFromNotification(notification)
          ]
          for (const event of events) safeEmit(event)
        },
        (params) => {
          const question = acpPermissionQuestion(params)
          if (question === undefined) {
            return Promise.resolve({ outcome: { outcome: "cancelled" as const } })
          }
          return enqueueQuestion({
            sessionId: question.sessionId,
            questions: [question.spec],
            ...(question.planDocument === undefined ? {} : { planDocument: question.planDocument }),
            cancelledResponse: { outcome: { outcome: "cancelled" as const } },
            responseFor: (answer) => acpPermissionOutcome(question.optionIds, answer)
          })
        },
        terminals,
        extension?.configureClientApp
      ).connect(
        acp.ndJsonStream(
          Writable.toWeb(child.stdin) as WritableStream<Uint8Array>,
          Readable.toWeb(child.stdout) as ReadableStream<Uint8Array>
        )
      )
      const answerQuestion = async (
        sessionId: string,
        questionId: string,
        answer: QuestionAnswer
      ): Promise<void> => {
        const pending = pendingQuestions.get(questionId)
        if (pending === undefined || pending.sessionId !== sessionId) {
          throw new Error(`No pending question: ${questionId}`)
        }
        pendingQuestions.delete(questionId)
        pending.resolve(pending.responseFor(answer))
        emitQuestionResolved(
          questionId,
          pending,
          answer.outcome === "answered" ? "answered" : "cancelled",
          answer.outcome === "answered" ? answer.answers : undefined
        )
      }
      /// ACP spec: a cancelled turn (and a closing connection) must resolve
      /// pending permission requests as cancelled.
      const cancelQuestions = (sessionId: string | undefined): void => {
        for (const [questionId, pending] of pendingQuestions) {
          if (sessionId !== undefined && pending.sessionId !== sessionId) continue
          pendingQuestions.delete(questionId)
          pending.resolve(pending.cancelledResponse)
          emitQuestionResolved(questionId, pending, "cancelled", undefined)
        }
      }
      closeConnection = (error) => {
        cancelQuestions(undefined)
        terminals?.closeAll()
        connection.close(error)
      }
      child.once("exit", () => {
        cancelQuestions(undefined)
        terminals?.closeAll()
        // A CLI that dies at startup can emit megabytes of minified bundle and
        // stack frames; this message reaches the UI, so summarize rather than
        // forward the captured tail verbatim.
        connection.close(
          new Error(summarizeProcessFailure(stderr(), `${request.command} exited unexpectedly`))
        )
      })
      let initialized: acp.InitializeResponse
      try {
        initialized = await promiseWithTimeout(
          Promise.race([
            connection.agent.request(acp.methods.agent.initialize, {
              clientCapabilities: acpClientCapabilities(request.harnessId, terminals !== undefined),
              clientInfo: {
                name: "Codevisor",
                title: "Codevisor",
                version: "0.1.0"
              },
              protocolVersion: acp.PROTOCOL_VERSION
            }),
            spawnFailure
          ]),
          options.connectTimeoutMs ?? 10_000,
          `ACP initialize timed out after ${options.connectTimeoutMs ?? 10_000}ms`
        )
      } catch (cause) {
        const raw = cause instanceof Error ? cause : new Error(String(cause))
        // A CLI that dies during startup surfaces here, not in `probeAuth`: the
        // SDK sees EOF on the pipes and rejects this request with a bare "ACP
        // connection closed" that says nothing about the cause. The child's
        // stderr does, so wait for it to flush and summarize that instead.
        let error = raw
        if (isGenericConnectionClose(raw.message)) {
          await settleStderr(child)
          error = new Error(summarizeProcessFailure(stderr(), raw.message))
        }
        closeConnection(error)
        terminate()
        throw error
      }
      const established = sdkConnection(connection, stderr, {
        terminate: () => {
          cancelQuestions(undefined)
          terminals?.closeAll()
          terminate()
        },
        promptCapabilities: initialized?.agentCapabilities?.promptCapabilities ?? {},
        questions: { answerQuestion, cancelQuestions },
        auth: {
          methods: (initialized?.authMethods ?? []).map((method) => ({
            id: method.id,
            name: method.name,
            ...(method.description == null ? {} : { description: method.description })
          })),
          canLogout: initialized?.agentCapabilities?.auth?.logout != null
        },
        ...(request.harnessId === "pi"
          ? {
              piStartupInfoBySession,
              piSessionError: (sessionId: string) =>
                readPiSessionError(sessionId, request.env.HOME ?? homedir())
            }
          : {}),
        harnessId: request.harnessId,
        ...(extension?.sdkConnectionCustomization === undefined
          ? {}
          : { customization: extension.sdkConnectionCustomization })
      })
      // Newer ACP agents report identity in the initialize response; read it
      // defensively so older protocol versions stay decodable.
      const reportedInfo = (
        initialized as { agentInfo?: { name?: string; version?: string } } | undefined
      )?.agentInfo
      return {
        ...established,
        agentInfo: {
          ...(reportedInfo?.name === undefined ? {} : { name: reportedInfo.name }),
          ...(reportedInfo?.version === undefined ? {} : { version: reportedInfo.version }),
          ...(typeof initialized?.protocolVersion === "number"
            ? { protocolVersion: initialized.protocolVersion }
            : {})
        }
      }
    })
})

export const makeStdioAcpConnector = (
  backgroundTerminals?: BackgroundTerminalIntegration,
  connectTimeoutMs = 10_000
): AcpConnector =>
  makeStdioAcpConnectorWithOptions({
    connectTimeoutMs,
    ...(backgroundTerminals === undefined ? {} : { backgroundTerminals })
  })

/// Result of a one-shot ACP handshake probe — the "Test Connection" action
/// for user-defined custom harnesses.
export interface AcpConnectionTestResult {
  readonly ok: boolean
  readonly agentName?: string
  readonly protocolVersion?: number
  readonly error?: string
}

/// Spawns `command args…` and performs the ACP initialize handshake, then
/// tears the process down. Never throws: failures (binary missing, not an
/// ACP agent, handshake timeout) come back as `{ ok: false, error }` so the
/// raw cause is showable to the harness developer.
export const testAcpConnection = async (
  launch: {
    readonly command: string
    readonly args: ReadonlyArray<string>
    readonly env?: Readonly<Record<string, string>>
  },
  options: {
    readonly env: NodeJS.ProcessEnv
    readonly cwd?: string
    readonly timeoutMs?: number
    /// Injected in tests; defaults to the stdio connector.
    readonly connector?: AcpConnector
  }
): Promise<AcpConnectionTestResult> => {
  const connector =
    options.connector ?? makeStdioAcpConnector(undefined, options.timeoutMs ?? 10_000)
  try {
    const connection = await Effect.runPromise(
      connector.connect(
        {
          args: launch.args,
          command: launch.command,
          cwd: options.cwd ?? homedir(),
          env: { ...options.env, ...launch.env },
          harnessId: "custom-harness-test"
        },
        () => Promise.resolve()
      )
    )
    const info = connection.agentInfo
    await Effect.runPromise(connection.close).catch(() => undefined)
    return {
      ok: true,
      ...(info?.name === undefined ? {} : { agentName: info.name }),
      ...(info?.protocolVersion === undefined ? {} : { protocolVersion: info.protocolVersion })
    }
  } catch (cause) {
    return {
      ok: false,
      error: cause instanceof Error ? cause.message : String(cause)
    }
  }
}

const promiseWithTimeout = <A>(
  promise: Promise<A>,
  timeoutMs: number,
  message: string
): Promise<A> => {
  let timer: ReturnType<typeof setTimeout> | undefined
  const timeout = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => reject(new Error(message)), timeoutMs)
    timer.unref()
  })
  return Promise.race([promise, timeout]).finally(() => {
    if (timer !== undefined) clearTimeout(timer)
  })
}

const processGroupTerminator = (child: ChildProcessWithoutNullStreams): (() => void) => {
  let terminated = false
  return () => {
    if (terminated) return
    terminated = true
    const pid = child.pid
    if (pid === undefined || process.platform === "win32") {
      child.kill()
      return
    }
    try {
      process.kill(-pid, "SIGTERM")
    } catch {
      child.kill()
    }
    const forceKill = setTimeout(() => {
      try {
        process.kill(-pid, "SIGKILL")
      } catch {
        // The process group already exited.
      }
    }, 1_000)
    forceKill.unref()
  }
}

export const stdioAcpConnector: AcpConnector = makeStdioAcpConnector()

/// Waits for a dying child's stderr to finish arriving, capped so a process
/// that keeps its pipe open can't stall a probe. The SDK rejects pending
/// requests the moment stdout hits EOF, which can beat the final stderr chunks
/// through the event loop — summarizing before this settles risks reading an
/// empty or half-written buffer.
const settleStderr = (child: ChildProcessWithoutNullStreams, timeoutMs = 250): Promise<void> =>
  new Promise((resolve) => {
    if (child.stderr.readableEnded) {
      resolve()
      return
    }
    const finish = (): void => {
      clearTimeout(timer)
      child.stderr.off("end", finish)
      child.stderr.off("close", finish)
      resolve()
    }
    const timer = setTimeout(finish, timeoutMs)
    timer.unref?.()
    child.stderr.once("end", finish)
    child.stderr.once("close", finish)
  })

const captureStderr = (child: ChildProcessWithoutNullStreams): (() => string) => {
  let buffer = ""
  child.stderr.setEncoding("utf8")
  child.stderr.on("data", (chunk: string) => {
    buffer = `${buffer}${chunk}`.slice(-8192)
  })
  return () => buffer
}
/* v8 ignore stop */
