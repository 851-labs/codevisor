import { isRecord } from "@codevisor/api"

import type { RuntimeEvent } from "./types.js"

const SDK_RESULT_PREFIX = /^Claude Code returned an error result:\s*/

const CLAUDE_EXIT =
  /^Claude Code process (?:exited with code \d+|terminated by signal \w+)(?:\. stderr: ([\s\S]*))?$/

const CLAUDE_STOPPED = "Claude Code stopped unexpectedly."

const PLAIN_FAILURES: ReadonlyArray<readonly [RegExp, string]> = [
  [
    /no conversation found with session id/i,
    "Claude Code couldn't find this chat's saved conversation."
  ],
  [/^Query closed before response received$/, CLAUDE_STOPPED],
  [/^ACP connection closed$/, "The agent stopped unexpectedly."]
]

export const plainFailureText = (text: string): string => {
  const stripped = text.trim().replace(SDK_RESULT_PREFIX, "")
  const exit = CLAUDE_EXIT.exec(stripped)
  if (exit !== null) {
    const stderr = exit[1]?.trim()
    return stderr === undefined || stderr === "" ? CLAUDE_STOPPED : `Claude Code stopped: ${stderr}`
  }
  const known = PLAIN_FAILURES.find(([pattern]) => pattern.test(stripped))
  return known === undefined ? stripped : known[1]
}

export const withPlainFailureText = (event: RuntimeEvent): RuntimeEvent => {
  const record = event.payload
  if (!isRecord(record)) return event
  if (event.kind === "session.error" && typeof record.message === "string") {
    return { ...event, payload: { ...record, message: plainFailureText(record.message) } }
  }
  if (event.kind === "session.updated" && typeof record.stopDetail === "string") {
    return { ...event, payload: { ...record, stopDetail: plainFailureText(record.stopDetail) } }
  }
  return event
}
