import { spawn } from "node:child_process"
import type { ChildProcessWithoutNullStreams } from "node:child_process"
import { randomUUID } from "node:crypto"
import { Readable, Writable } from "node:stream"

import * as acp from "@agentclientprotocol/sdk"
import {
  adapterPromise,
  answersIfDefined,
  questionIdFirstPayloads,
  questionReplyText,
  skillsUpdateEvent,
  summarizeProcessFailure,
  type AgentSessionMetadata,
  type PromptInput,
  type QuestionAnswer,
  type QuestionOutcome,
  type RuntimeEmit,
  type RuntimeEvent
} from "@codevisor/agent-runtime"
import { trackProcessTree } from "@codevisor/processes"
import { Effect } from "effect"

import { rewriteAgentLines } from "./agent-lines.js"
import { createClientApp, type ConfigureAcpClientApp } from "./client-app.js"
import { acpClientCapabilities, type AcpConnector } from "./connection.js"
import { isGenericConnectionClose } from "./internal.js"
import { runtimeEventFromNotification } from "./notifications.js"
import { makeAcpPermissionPolicy } from "./permission-policy.js"
import {
  acpPermissionDecline,
  acpPermissionOutcome,
  acpPermissionQuestion,
  type AcpMappedQuestion,
  type PendingAcpQuestion
} from "./questions.js"
import {
  advertisesSteering,
  sdkConnection,
  type AcpSdkConnectionCustomization
} from "./sdk-connection.js"
import { discoverSkillFolders, makeAcpSkillTracker } from "./skills.js"

const questionPayloads = questionIdFirstPayloads(answersIfDefined)

export interface AcpStdioExtensionContext {
  readonly emit: (event: RuntimeEvent) => void
  readonly enqueueQuestion: <Response>(question: AcpMappedQuestion<Response>) => Promise<Response>
}

export interface AcpStdioExtension {
  readonly customizeClientCapabilities?: (
    capabilities: acp.ClientCapabilities
  ) => acp.ClientCapabilities
  readonly configureClientApp?: ConfigureAcpClientApp
  readonly mapSessionNotification?: (
    notification: acp.SessionNotification
  ) => ReadonlyArray<RuntimeEvent>
  readonly sdkConnectionCustomization?: AcpSdkConnectionCustomization
  readonly rewriteAgentLine?: (line: string) => string
}

export type AcpStdioExtensionFactory = (context: AcpStdioExtensionContext) => AcpStdioExtension

export interface StdioAcpConnectorOptions {
  readonly connectTimeoutMs?: number
  readonly extension?: AcpStdioExtensionFactory
}

/* v8 ignore start */
const ignoringEmitFailures =
  (emit: RuntimeEmit) =>
  (event: RuntimeEvent): void => {
    void emit(event).catch(() => undefined)
  }

export const makeStdioAcpConnectorWithOptions = (
  options: StdioAcpConnectorOptions = {}
): AcpConnector => ({
  connect: (request, emit) =>
    adapterPromise("connect", async () => {
      const child = spawn(request.command, [...request.args], {
        cwd: request.cwd,
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
      const permissions = makeAcpPermissionPolicy()
      const safeEmit = ignoringEmitFailures(emit)
      const emitQuestionResolved = (
        questionId: string,
        pending: PendingAcpQuestion,
        outcome: QuestionOutcome,
        answers: QuestionAnswer["answers"]
      ): void => {
        safeEmit({
          kind: "session.output",
          payload: questionPayloads.resolved(questionId, pending.questions, {
            outcome,
            answers
          }),
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
          payload: questionPayloads.asked(questionId, question.questions),
          subjectId: question.sessionId
        })
        return new Promise<Response>((resolve) => {
          pendingQuestions.set(questionId, {
            answer: (answer) => resolve(question.responseFor(answer)),
            cancel: () => resolve(question.cancelledResponse),
            reply: (replyText) => {
              const reply = question.replyFor(replyText)
              resolve(reply.response)
              return reply.delivered
            },
            questions: question.questions,
            sessionId: question.sessionId
          })
        })
      }
      const extension = options.extension?.({ emit: safeEmit, enqueueQuestion })
      const skills = makeAcpSkillTracker(() => discoverSkillFolders(request.cwd, request.env.HOME))
      const connection = createClientApp(
        (notification) => {
          if (notification.update.sessionUpdate === "current_mode_update") {
            permissions.modeChanged(notification.sessionId, notification.update.currentModeId)
          }
          if (notification.update.sessionUpdate === "available_commands_update") {
            const sessionId = notification.sessionId
            skills.update(sessionId, notification.update.availableCommands).then(
              (changed) => {
                if (changed !== undefined) safeEmit(skillsUpdateEvent(sessionId, changed))
              },
              () => undefined
            )
          }
          const events = extension?.mapSessionNotification?.(notification) ?? [
            runtimeEventFromNotification(notification)
          ]
          for (const event of events) safeEmit(event)
        },
        (params) => {
          const automatic = permissions.automaticOutcome(params)
          if (automatic !== undefined) return Promise.resolve(automatic)
          const question = acpPermissionQuestion(params)
          if (question === undefined) {
            return Promise.resolve({ outcome: { outcome: "cancelled" as const } })
          }
          return enqueueQuestion({
            sessionId: question.sessionId,
            questions: [question.spec],
            ...(question.planDocument === undefined ? {} : { planDocument: question.planDocument }),
            cancelledResponse: { outcome: { outcome: "cancelled" as const } },
            responseFor: (answer) => acpPermissionOutcome(question.optionIds, answer),
            replyFor: () => acpPermissionDecline(question.rejectOptionId)
          })
        },
        extension?.configureClientApp
      ).connect(acp.ndJsonStream(Writable.toWeb(child.stdin), agentOutputStream(extension, child)))
      const takePendingQuestion = (sessionId: string, questionId: string): PendingAcpQuestion => {
        const pending = pendingQuestions.get(questionId)
        if (pending === undefined || pending.sessionId !== sessionId) {
          throw new Error(`No pending question: ${questionId}`)
        }
        pendingQuestions.delete(questionId)
        return pending
      }
      const answerQuestion = async (
        sessionId: string,
        questionId: string,
        answer: QuestionAnswer
      ): Promise<void> => {
        const pending = takePendingQuestion(sessionId, questionId)
        pending.answer(answer)
        emitQuestionResolved(
          questionId,
          pending,
          answer.outcome === "answered" ? "answered" : "cancelled",
          answer.outcome === "answered" ? answer.answers : undefined
        )
      }
      const replyToQuestion = async (
        sessionId: string,
        questionId: string,
        reply: PromptInput
      ): Promise<boolean> => {
        const pending = takePendingQuestion(sessionId, questionId)
        const delivered = pending.reply(questionReplyText(reply))
        emitQuestionResolved(questionId, pending, "replied", undefined)
        return delivered
      }
      const cancelQuestions = (sessionId: string | undefined): void => {
        for (const [questionId, pending] of pendingQuestions) {
          if (sessionId !== undefined && pending.sessionId !== sessionId) continue
          pendingQuestions.delete(questionId)
          pending.cancel()
          emitQuestionResolved(questionId, pending, "cancelled", undefined)
        }
      }
      closeConnection = (error) => {
        cancelQuestions(undefined)
        connection.close(error)
      }
      child.once("exit", () => {
        cancelQuestions(undefined)
        connection.close(
          new Error(summarizeProcessFailure(stderr(), `${request.command} exited unexpectedly`))
        )
      })
      let initialized: acp.InitializeResponse
      const clientCapabilities = acpClientCapabilities()
      try {
        initialized = await promiseWithTimeout(
          Promise.race([
            connection.agent.request(acp.methods.agent.initialize, {
              clientCapabilities:
                extension?.customizeClientCapabilities?.(clientCapabilities) ?? clientCapabilities,
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
        let error = raw
        if (isGenericConnectionClose(raw.message)) {
          await settleStderr(child)
          error = new Error(summarizeProcessFailure(stderr(), raw.message))
        }
        closeConnection(error)
        await terminate()
        throw error
      }
      const established = sdkConnection(connection, stderr, {
        terminate: async () => {
          cancelQuestions(undefined)
          await terminate()
        },
        promptCapabilities: initialized?.agentCapabilities?.promptCapabilities ?? {},
        steering: advertisesSteering(initialized),
        canLoadSession: initialized?.agentCapabilities?.loadSession === true,
        questions: { answerQuestion, replyToQuestion, cancelQuestions },
        skills,
        auth: {
          methods: (initialized?.authMethods ?? []).map((method) => ({
            id: method.id,
            name: method.name,
            ...(method.description == null ? {} : { description: method.description }),
            ...(method._meta?.external_provider === true ? { external: true } : {})
          })),
          canLogout: initialized?.agentCapabilities?.auth?.logout != null
        },
        ...(extension?.sdkConnectionCustomization === undefined
          ? {}
          : { customization: extension.sdkConnectionCustomization })
      })
      const reportedInfo = initialized?.agentInfo
      const withModes = Effect.map((metadata: AgentSessionMetadata) => {
        permissions.sessionModes(metadata.sessionId, metadata.modes)
        return metadata
      })
      return {
        ...established,
        createSession: (cwd, toolGateway, skillListTimeoutMs) =>
          established.createSession(cwd, toolGateway, skillListTimeoutMs).pipe(withModes),
        loadSession: (sessionId, cwd, toolGateway, skillListTimeoutMs) =>
          established.loadSession(sessionId, cwd, toolGateway, skillListTimeoutMs).pipe(withModes),
        setMode: (sessionId, modeId) =>
          established
            .setMode(sessionId, modeId)
            .pipe(Effect.map(() => permissions.modeChanged(sessionId, modeId))),
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

const agentOutputStream = (
  extension: AcpStdioExtension | undefined,
  child: ChildProcessWithoutNullStreams
): ReadableStream<Uint8Array> => {
  if (extension?.rewriteAgentLine === undefined) return byteStream(child.stdout)
  return rewriteAgentLines(byteStream(child.stdout), extension.rewriteAgentLine)
}

const byteStream = (source: Readable): ReadableStream<Uint8Array> => {
  const reader = Readable.toWeb(source).getReader()
  return new ReadableStream<Uint8Array>({
    pull: async (controller) => {
      const { done, value } = await reader.read()
      if (done) controller.close()
      else if (value instanceof Uint8Array) controller.enqueue(value)
      else controller.error(new TypeError("ACP agent stdout produced a non-byte chunk"))
    },
    cancel: (reason) => reader.cancel(reason)
  })
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

const trackDetachedProcessTree = (
  child: ChildProcessWithoutNullStreams
): ReturnType<typeof trackProcessTree> | undefined => {
  if (child.pid === undefined) return undefined
  return trackProcessTree(child.pid, { detached: true })
}

const processGroupTerminator = (child: ChildProcessWithoutNullStreams): (() => Promise<void>) => {
  const tree = trackDetachedProcessTree(child)
  tree?.catch(() => undefined)
  return async () => {
    if (tree === undefined) {
      child.kill()
      return
    }
    await (await tree).stop()
  }
}

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
