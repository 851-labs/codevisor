export interface Reporter {
  readonly step: (message: string) => void
  readonly done: (message: string) => void
  readonly failure: (message: string) => void
  readonly result: (value: string) => void
}

export interface ReporterOutput {
  readonly log: (line: string) => void
  readonly data: (line: string) => void
}

export const processOutput: ReporterOutput = {
  log: (line) => process.stderr.write(`${line}\n`),
  data: (line) => process.stdout.write(`${line}\n`)
}

const colors = { step: "\u001B[36m", done: "\u001B[32m", failure: "\u001B[31m", reset: "\u001B[0m" }

export function createReporter(
  environment: NodeJS.ProcessEnv = process.env,
  output: ReporterOutput = processOutput,
  isTerminal = process.stderr.isTTY
): Reporter {
  if (environment.GITHUB_ACTIONS === "true") return githubReporter(output)

  return glyphReporter(output, usesColor(environment, isTerminal))
}

function glyphReporter(output: ReporterOutput, color: boolean): Reporter {
  const paint = (kind: keyof typeof colors, glyph: string, message: string) =>
    output.log(color ? `${colors[kind]}${glyph}${colors.reset} ${message}` : `${glyph} ${message}`)
  return {
    step: (message) => paint("step", "▸", message),
    done: (message) => paint("done", "✓", message),
    failure: (message) => paint("failure", "✗", message),
    result: (value) => output.data(value)
  }
}

function githubReporter(output: ReporterOutput): Reporter {
  return {
    step: (message) => output.log(`▸ ${message}`),
    done: (message) => output.log(`✓ ${message}`),
    failure: (message) => output.log(`::error::${escapeCommand(message)}`),
    result: (value) => output.data(value)
  }
}

function usesColor(environment: NodeJS.ProcessEnv, isTerminal: boolean): boolean {
  if (environment.FORCE_COLOR !== undefined && environment.FORCE_COLOR !== "0") return true

  return isTerminal && environment.NO_COLOR === undefined
}

function escapeCommand(message: string): string {
  return message.replaceAll("%", "%25").replaceAll("\r", "%0D").replaceAll("\n", "%0A")
}
