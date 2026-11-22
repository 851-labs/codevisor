import { userInfo } from "node:os"

import { redactSecrets } from "@codevisor/agent-runtime"

export const maxDiagnosticTextLength = 1_000

export const scrubDiagnosticText = (text: string): string =>
  replaceUserNames(redactSecrets(replacePatterns(text))).slice(0, maxDiagnosticTextLength)

const patterns: ReadonlyArray<readonly [RegExp, string]> = [
  [/(?<![\w:/.~])~?\/(?:[^\s/"'`:,;()[\]<>]+\/)+[^\s/"'`:,;()[\]<>]*/g, "<path>"],
  [/[\w.%+-]+@[a-z\d.-]+\.[a-z]{2,}/gi, "<email>"],
  [/\b(?:sk|pk|rk)-[\w-]{16,}/g, "<redacted>"],
  [/\bgh[pousr]_[a-z\d]{16,}/gi, "<redacted>"],
  [/\bgithub_pat_\w{16,}/g, "<redacted>"],
  [/\bxox[abprs]-[a-z\d-]+/gi, "<redacted>"]
]

const minimumNameLength = 3

const replacePatterns = (text: string): string =>
  patterns.reduce(
    (scrubbed, [pattern, replacement]) => scrubbed.replace(pattern, replacement),
    text
  )

const replaceUserNames = (text: string): string =>
  userNames().reduce((scrubbed, name) => scrubbed.replaceAll(name, "<user>"), text)

const userNames = (): ReadonlyArray<string> => {
  const name = currentUserName()
  return name !== undefined && name.length >= minimumNameLength ? [name] : []
}

const currentUserName = (): string | undefined => {
  try {
    return userInfo().username
  } catch {
    return undefined
  }
}
