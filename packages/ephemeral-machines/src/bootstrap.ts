import {
  EphemeralProviderError,
  type EphemeralProvider,
  type ExecResult,
  type OutputStream
} from "./provider.js"

export const DEFAULT_INSTALL_URL = "https://www.codevisor.dev/install.sh"
export const SIGN_IN_MARKER = "::codevisor-stage::signIn"

export interface BootstrapRequest {
  readonly inviteCode: string
  readonly machineName: string
  readonly installUrl?: string
  readonly installEnvironment?: Readonly<Record<string, string>>
  readonly serverEnvironment?: Readonly<Record<string, string>>
  readonly timeoutMs?: number
}

const bootstrapTimeoutMs = 15 * 60 * 1000
const outputTailLines = 30

export const bootstrapMachine = async (
  provider: EphemeralProvider,
  providerMachineId: string,
  request: BootstrapRequest,
  onOutput?: (stream: OutputStream, text: string) => void
): Promise<ExecResult> => {
  const result = await provider.exec(providerMachineId, {
    script: bootstrapScript(request),
    stdin: `${request.inviteCode}\n`,
    timeoutMs: request.timeoutMs ?? bootstrapTimeoutMs,
    ...(onOutput === undefined ? {} : { onOutput })
  })
  if (result.exitCode !== 0) throw bootstrapFailure(provider, result, request.inviteCode)

  return result
}

export const bootstrapScript = (request: BootstrapRequest): string =>
  [
    "set -eu",
    "export CODEVISOR_NO_SETUP=1 CODEVISOR_NO_SERVICE=1 CODEVISOR_INSTALL_SERVER=1",
    'installer="$(mktemp)"',
    `curl -fsSL ${shellQuote(request.installUrl ?? DEFAULT_INSTALL_URL)} -o "$installer"`,
    `${environmentAssignments(request.installEnvironment)}sh "$installer"`,
    `printf '%s\\n' ${shellQuote(SIGN_IN_MARKER)}`,
    ...serverStartLines(request.serverEnvironment),
    `as_server "$home/.local/bin/codevisor" auth login --invite - --name ${shellQuote(request.machineName)}`,
    ""
  ].join("\n")

export const startServerScript = (serverEnvironment?: Readonly<Record<string, string>>): string =>
  ["set -eu", ...serverStartLines(serverEnvironment), ""].join("\n")

const serverStartLines = (
  serverEnvironment: Readonly<Record<string, string>> | undefined
): ReadonlyArray<string> => [
  'if [ "$(id -u)" = 0 ]; then',
  "  home=$(getent passwd codevisor | cut -d: -f6)",
  '  as_server() { runuser -u codevisor -- env HOME="$home" USER=codevisor "$@"; }',
  "else",
  '  home="$HOME"',
  '  as_server() { env "$@"; }',
  "fi",
  `as_server ${environmentAssignments(serverEnvironment)}"$home/.local/bin/codevisor" start </dev/null`
]

export const shellQuote = (value: string): string => `'${value.replaceAll("'", `'\\''`)}'`

const environmentAssignments = (
  environment: Readonly<Record<string, string>> | undefined
): string =>
  Object.entries(environment ?? {})
    .map(([key, value]) => `${key}=${shellQuote(value)} `)
    .join("")

const bootstrapFailure = (
  provider: EphemeralProvider,
  result: ExecResult,
  inviteCode: string
): EphemeralProviderError =>
  new EphemeralProviderError(
    provider.id,
    `Installing Codevisor on the ${provider.displayName} machine failed (exit ${result.exitCode}):\n${outputTail(result, inviteCode)}`
  )

const outputTail = (result: ExecResult, inviteCode: string): string =>
  `${result.stdout}${result.stderr}`
    .replaceAll(inviteCode, "[invite]")
    .trimEnd()
    .split("\n")
    .slice(-outputTailLines)
    .join("\n")
