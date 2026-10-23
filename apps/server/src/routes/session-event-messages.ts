import type { ExecutionJob, QuestionPayload, SessionSummary } from "@codevisor/api"

export interface SessionEventMessage {
  readonly key: string
  readonly text: string
}

export const REPORT_LIMIT = 4_000

const EVENT_OPENING = "<codevisor-event "

export const attribute = (value: string): string =>
  value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;")

export const turnEndedMessage = (
  target: Pick<SessionSummary, "id" | "title">,
  stopReason: string | undefined,
  finalText: string,
  subscriptionId?: string
): SessionEventMessage => {
  const stop = stopReason === undefined ? "" : ` stopReason="${attribute(stopReason)}"`
  return {
    key: `turn_ended:${target.id}`,
    text: eventBlock(
      `type="session.turn_ended" agentId="${attribute(target.id)}" title="${attribute(target.title)}"${stop}${subscriptionAttribute(subscriptionId)}`,
      orPlaceholder(finalText, "(no final message)")
    )
  }
}

export const waitingForUserMessage = (
  target: Pick<SessionSummary, "id" | "title">,
  kind: string,
  question: QuestionPayload | undefined,
  subscriptionId?: string
): SessionEventMessage => ({
  key: `waiting_for_user:${target.id}`,
  text: eventBlock(
    `type="session.waiting_for_user" agentId="${attribute(target.id)}" title="${attribute(target.title)}" kind="${attribute(kind)}"${subscriptionAttribute(subscriptionId)}`,
    waitingBody(kind, question)
  )
})

export const erroredMessage = (
  target: Pick<SessionSummary, "id" | "title">,
  message: string,
  subscriptionId?: string
): SessionEventMessage => ({
  key: `errored:${target.id}`,
  text: eventBlock(
    `type="session.errored" agentId="${attribute(target.id)}" title="${attribute(target.title)}"${subscriptionAttribute(subscriptionId)}`,
    bounded(message, "(no error message)")
  )
})

export const jobFinishedMessage = (
  job: ExecutionJob,
  subscriptionId?: string
): SessionEventMessage => ({
  key: `job_finished:${job.jobId}`,
  text: eventBlock(
    `type="execution.job_finished" jobId="${attribute(job.jobId)}" agentId="${attribute(job.sessionId)}" state="${job.state}" description="${attribute(job.description)}"${subscriptionAttribute(subscriptionId)}`,
    [bounded(jobOutcome(job), "(no result)"), `Full output: ${job.outputPath}`].join("\n")
  )
})

export const fromMachine = (
  message: SessionEventMessage,
  machine: { readonly id: string; readonly name: string }
): SessionEventMessage => ({
  key: message.key,
  text: message.text.replace(
    EVENT_OPENING,
    `${EVENT_OPENING}machine="${attribute(machine.name)}" machineId="${attribute(machine.id)}" `
  )
})

export const combinedEventText = (messages: ReadonlyArray<SessionEventMessage>): string =>
  messages.map((message) => message.text).join("\n\n")

const eventBlock = (attributes: string, body: string): string =>
  [`${EVENT_OPENING}${attributes}>`, body, "</codevisor-event>"].join("\n")

const subscriptionAttribute = (subscriptionId: string | undefined): string =>
  subscriptionId === undefined ? "" : ` subscriptionId="${attribute(subscriptionId)}"`

const orPlaceholder = (text: string, empty: string): string => (text.length === 0 ? empty : text)

const bounded = (text: string, empty: string): string => {
  if (text.length <= REPORT_LIMIT) return orPlaceholder(text, empty)
  return `${text.slice(0, REPORT_LIMIT)}\n…(truncated)`
}

const waitingBody = (kind: string, question: QuestionPayload | undefined): string => {
  if (question === undefined) return `The session is waiting for ${kindLabel(kind)}.`
  const asked = JSON.stringify({
    questionId: question.questionId,
    ...(question.message === undefined ? {} : { message: question.message }),
    questions: question.questions
  })
  return `${bounded(asked, "")}\nAnswer it with sessions.question_answer.`
}

const kindLabel = (kind: string): string =>
  kind === "planApproval" ? "plan approval" : "an answer"

const jobOutcome = (job: ExecutionJob): string => {
  if (job.state === "completed") return `Result: ${safeJson(job.result)}`
  return `Error: ${job.error ?? job.state}`
}

const safeJson = (value: unknown): string => {
  try {
    return JSON.stringify(value) ?? "undefined"
  } catch {
    return String(value)
  }
}
