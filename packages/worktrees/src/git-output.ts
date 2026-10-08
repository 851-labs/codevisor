import type { ChildProcessWithoutNullStreams } from "node:child_process"
import type { Readable } from "node:stream"

export type GitOutputStream = "stdout" | "stderr"
export type GitOutputListener = (stream: GitOutputStream, line: string) => void

/// Matches ANSI escape sequences - CSI (colors, cursor moves, erase), OSC
/// (titles/links), and single-character escapes - that TUI-style checkout
/// hooks emit. Setup logs render as plain text, so these are stripped.
// oxlint-disable no-control-regex
const ansiEscapePattern =
  /\u001B(?:\[[0-9:;<=>?]*[ -/]*[@-~]|\][^\u0007\u001B]*(?:\u0007|\u001B\\)?|[@-Z\\^_])/g
// oxlint-enable no-control-regex

/// Strips ANSI escapes and stray control characters and trims trailing
/// whitespace, leaving a human-readable log line (possibly empty).
export const sanitizeGitOutputLine = (line: string): string =>
  line
    .replace(ansiEscapePattern, "")
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0000-\u0008\u000B-\u001F\u007F]/g, "")
    .trimEnd()

interface CommandOutput {
  readonly stderrLines: Array<string>
  readonly onOutput: GitOutputListener | undefined
}

interface StreamOutput {
  readonly name: GitOutputStream
  buffered: string
  lastLine: string | undefined
}

const streamOutput = (name: GitOutputStream): StreamOutput => ({
  name,
  buffered: "",
  lastLine: undefined
})

const acceptSanitizedLine = (output: CommandOutput, stream: StreamOutput, raw: string): void => {
  const line = sanitizeGitOutputLine(raw)
  if (line.length === 0 || line === stream.lastLine) return
  stream.lastLine = line
  if (stream.name === "stderr") output.stderrLines.push(line)
  const onOutput = output.onOutput
  onOutput?.(stream.name, line)
}

/// Bare CR frames support progress repainting; each stream retains its own remainder.
const appendCompleteLines = (output: CommandOutput, stream: StreamOutput, chunk: string): void => {
  stream.buffered += chunk
  const lines = stream.buffered.split(/\r?\n|\r/)
  // split always yields at least one element, so pop never returns undefined.
  stream.buffered = lines.pop() as string
  for (const line of lines) acceptSanitizedLine(output, stream, line)
}

const flushRemainder = (output: CommandOutput, stream: StreamOutput): void => {
  if (stream.buffered.length > 0) {
    acceptSanitizedLine(output, stream, stream.buffered)
    stream.buffered = ""
  }
}

const attachStream = (readable: Readable, output: CommandOutput, stream: StreamOutput): void => {
  readable.on("data", (chunk: string) => appendCompleteLines(output, stream, chunk))
}

/// Synchronous output ownership for one spawned Git command. Settlement and
/// diagnostic construction stay with the operation that spawned it.
export class GitCommandOutput {
  readonly stderrLines: Array<string> = []
  private readonly output: CommandOutput
  private readonly stdout = streamOutput("stdout")
  private readonly stderr = streamOutput("stderr")

  constructor(child: ChildProcessWithoutNullStreams, onOutput: GitOutputListener | undefined) {
    this.output = { stderrLines: this.stderrLines, onOutput }
    child.stdout.setEncoding("utf8")
    child.stderr.setEncoding("utf8")
    attachStream(child.stdout, this.output, this.stdout)
    attachStream(child.stderr, this.output, this.stderr)
  }

  flush(): void {
    flushRemainder(this.output, this.stdout)
    flushRemainder(this.output, this.stderr)
  }
}
