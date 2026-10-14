import type { HarnessAuthInspection } from "@codevisor/agent-runtime"

import type { AgyRunResult } from "./client.js"
import { signedOut } from "./protocol.js"

export const AGY_GEMINI_DIR_ENV = "CODEVISOR_AGY_GEMINI_DIR"

export const AGY_FILE_TOKENS_ENV = { SSH_CLIENT: "127.0.0.1 0 0" }

export const agyAccountLaunch = (
  env: NodeJS.ProcessEnv
): {
  readonly args: Array<string>
  readonly env: NodeJS.ProcessEnv
  readonly geminiDir: string | undefined
} => {
  const { [AGY_GEMINI_DIR_ENV]: dir, ...rest } = env
  const geminiDir = dir === undefined || dir === "" ? undefined : dir
  return {
    args: geminiDir === undefined ? [] : [`--gemini_dir=${geminiDir}`],
    env: {
      ...rest,
      ...(geminiDir === undefined ? {} : AGY_FILE_TOKENS_ENV),
      AGY_CLI_DISABLE_AUTO_UPDATE: "true"
    },
    geminiDir
  }
}

export const agyAuthInspection = (result: AgyRunResult): HarnessAuthInspection => {
  if (result.code === 0) return { state: "authenticated", methods: [], canLogout: true }
  const message = `${result.stderr}\n${result.stdout}`.trim()
  if (signedOut(message))
    return {
      state: "unauthenticated",
      methods: [],
      canLogout: false,
      detail: "Sign in to Antigravity with your Google account or a Gemini API key."
    }
  return {
    state: "error",
    methods: [],
    canLogout: false,
    detail:
      message.split("\n").find((line) => line.trim() !== "" && !line.startsWith("Fetching")) ??
      `agy exited with status ${result.code}`
  }
}

export interface AgyTerminal {
  readonly write: (data: string) => void
  readonly onData: (handler: (data: string) => void) => void
  readonly onExit: (handler: (code: number) => void) => void
  readonly kill: () => void
}

export type AgyTerminalSpawner = (request: {
  readonly command: string
  readonly args: ReadonlyArray<string>
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
}) => Promise<AgyTerminal>

const replies: ReadonlyArray<readonly [string, string]> = [
  ["\x1b[>c", "\x1b[>1;10;0c"],
  ["\x1b[>0c", "\x1b[>1;10;0c"],
  ["\x1b[c", "\x1b[>1;10;0c"],
  ["\x1b[6n", "\x1b[1;1R"],
  ["\x1b]10;?", "\x1b]10;rgb:ffff/ffff/ffff\x1b\\"],
  ["\x1b]11;?", "\x1b]11;rgb:0000/0000/0000\x1b\\"]
]

const ANSI =
  // oxlint-disable-next-line no-control-regex
  /\x1b\[[0-9;?>]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][0-9A-Za-z]|\x1b[=>]/g

export const signInUrl = (screen: string): string | undefined =>
  // oxlint-disable-next-line no-control-regex
  /\x1b\]8;[^;]*;(https:\/\/accounts\.google\.com\/[^\x07\x1b]+)(?:\x07|\x1b\\)/.exec(screen)?.[1]

const failure = (screen: string): string | undefined =>
  screen
    .replace(ANSI, "")
    .split(/\r?\n|\r/)
    .map((line) => line.trim())
    .find((line) => /invalid|failed|error|denied|expired/i.test(line))

const OAUTH_ERROR =
  /\b(invalid_grant|invalid_request|access_denied|invalid_client|unauthorized_client)\b/

const refusal = (screen: string): string | undefined => {
  const code = OAUTH_ERROR.exec(screen.replace(ANSI, ""))?.[1]
  return code === undefined
    ? undefined
    : `Google didn't accept that code (${code}). Start again and paste the new code.`
}

export interface AgyLogin {
  readonly url: string
  readonly submit: (code: string) => Promise<void>
  readonly cancel: () => void
}

export interface AgyLoginOptions {
  readonly spawn: AgyTerminalSpawner
  readonly command: string
  readonly cwd: string
  readonly env: NodeJS.ProcessEnv
  readonly signedIn: () => Promise<boolean>
  readonly wait: (ms: number) => Promise<unknown>
  readonly urlDeadlineMs?: number
  readonly checks?: number
}

export const startAgyLogin = async (options: AgyLoginOptions): Promise<AgyLogin> => {
  const launch = agyAccountLaunch(options.env)
  if (launch.geminiDir === undefined)
    throw new Error("Run agy in a terminal to sign in to your own Antigravity, or add an account.")
  const terminal = await options.spawn({
    command: options.command,
    args: launch.args,
    cwd: options.cwd,
    env: { ...launch.env, TERM: "xterm-256color" }
  })
  let screen = ""
  let chose = false
  let exited: number | undefined
  const found = Promise.withResolvers<string>()
  terminal.onData((data) => {
    screen = `${screen}${data}`.slice(-64 * 1024)
    for (const [query, reply] of replies) if (data.includes(query)) terminal.write(reply)
    if (!chose && /Select login method/.test(screen.replace(ANSI, ""))) {
      chose = true
      terminal.write("\r")
    }
    const url = signInUrl(screen)
    if (url !== undefined) found.resolve(url)
  })
  terminal.onExit((code) => {
    exited = code
    found.reject(
      new Error(failure(screen) ?? "Antigravity closed before it showed a sign-in link.")
    )
  })
  const timer = setTimeout(
    () => found.reject(new Error("Antigravity didn't show a sign-in link in time.")),
    options.urlDeadlineMs ?? 30_000
  )
  let url: string
  try {
    url = await found.promise
  } catch (cause) {
    terminal.kill()
    throw cause
  } finally {
    clearTimeout(timer)
  }
  return {
    url,
    submit: async (code) => {
      const before = screen.length
      terminal.write(`${code.trim()}\r`)
      try {
        for (let check = 0; check < (options.checks ?? 30); check += 1) {
          await options.wait(2_000)
          const reported = refusal(screen.slice(before))
          if (reported !== undefined) throw new Error(reported)
          if (await options.signedIn()) return
          if (exited !== undefined) break
        }
        throw new Error("Antigravity didn't accept that code. Start again and paste the new code.")
      } finally {
        terminal.kill()
      }
    },
    cancel: () => terminal.kill()
  }
}

/* v8 ignore start */
export const spawnAgyTerminal: AgyTerminalSpawner = async (request) => {
  const pty = await import("node-pty")
  const child = pty.spawn(request.command, [...request.args], {
    cols: 160,
    rows: 48,
    cwd: request.cwd,
    env: request.env as Record<string, string>,
    name: "xterm-256color"
  })
  return {
    write: (data) => child.write(data),
    onData: (handler) => void child.onData(handler),
    onExit: (handler) => void child.onExit(({ exitCode }) => handler(exitCode)),
    kill: () => {
      try {
        child.kill()
      } catch {}
    }
  }
}
/* v8 ignore stop */
