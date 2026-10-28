import {
  SandboxProviderError,
  type SandboxProvider,
  type ExecResult,
  type OutputStream
} from "./provider.js"

export const DEFAULT_INSTALL_URL = "https://www.codevisor.dev/install.sh"
export const SIGN_IN_MARKER = "::codevisor-stage::signIn"
export const APP_LAUNCHER = "~/.codevisor/open-app"

export interface BootstrapRequest {
  readonly inviteCode: string
  readonly machineName: string
  readonly installUrl?: string
  readonly installEnvironment?: Readonly<Record<string, string>>
  readonly serverEnvironment?: Readonly<Record<string, string>>
  readonly timeoutMs?: number
  readonly preinstalled?: boolean
}

const bootstrapTimeoutMs = 15 * 60 * 1000
const outputTailLines = 30
const swapFloorKb = 2 * 1024 * 1024

export const bootstrapMachine = async (
  provider: SandboxProvider,
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
    ...installLines(request),
    `printf '%s\\n' ${shellQuote(SIGN_IN_MARKER)}`,
    ...serverStartLines(request.serverEnvironment),
    `as_server "$home/.local/bin/codevisor" auth login --invite - --name ${shellQuote(request.machineName)}`,
    ""
  ].join("\n")

const installLines = (request: BootstrapRequest): ReadonlyArray<string> => {
  if (request.preinstalled === true) return []

  return [
    ...swapLines,
    "export CODEVISOR_NO_SETUP=1 CODEVISOR_NO_SERVICE=1 CODEVISOR_INSTALL_SERVER=1",
    "unset SUDO_USER",
    'installer="$(mktemp)"',
    `curl -fsSL ${shellQuote(request.installUrl ?? DEFAULT_INSTALL_URL)} -o "$installer"`,
    `${environmentAssignments(request.installEnvironment)}sh "$installer"`
  ]
}

const swapLines: ReadonlyArray<string> = [
  `if [ "$(id -u)" = 0 ] && [ -r /proc/meminfo ] && [ "$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)" -lt ${swapFloorKb} ] && [ -z "$(swapon --noheadings 2>/dev/null)" ]; then`,
  "  { fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile && echo 'Added 2 GB of swap'; } || rm -f /swapfile",
  "fi"
]

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
  `as_server ${environmentAssignments(serverEnvironment)}"$home/.local/bin/codevisor" start </dev/null`,
  `if [ -x "$home/${APP_LAUNCHER.slice(2)}" ]; then "$home/${APP_LAUNCHER.slice(2)}"; fi`
]

export const shellQuote = (value: string): string => `'${value.replaceAll("'", `'\\''`)}'`

export const environmentAssignments = (
  environment: Readonly<Record<string, string>> | undefined
): string =>
  Object.entries(environment ?? {})
    .map(([key, value]) => `${key}=${shellQuote(value)} `)
    .join("")

const bootstrapFailure = (
  provider: SandboxProvider,
  result: ExecResult,
  inviteCode: string
): SandboxProviderError =>
  new SandboxProviderError(
    provider.definition.id,
    `Installing Codevisor on the ${provider.definition.displayName} machine failed (exit ${result.exitCode}):\n${outputTail(result, inviteCode)}`
  )

const outputTail = (result: ExecResult, inviteCode: string): string =>
  `${result.stdout}${result.stderr}`
    .replaceAll(inviteCode, "[invite]")
    .trimEnd()
    .split("\n")
    .slice(-outputTailLines)
    .join("\n")
