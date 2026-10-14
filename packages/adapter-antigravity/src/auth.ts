import type { HarnessAuthInspection } from "@codevisor/agent-runtime"

import type { AgyRunResult } from "./client.js"
import { signedOut } from "./protocol.js"

/// Antigravity sign-in. agy has no sign-in command: its TUI asks on first
/// launch. Run as if over SSH, it shows a Google OAuth link, takes the code
/// the callback page shows, and keeps the sign-in in a file under its data
/// root instead of the login Keychain — so each Codevisor-managed account,
/// with its own data root, holds a sign-in of its own.

/// An account context's agy data root; the adapter passes it as
/// `--gemini_dir` (agy reads no variable for it).
export const AGY_GEMINI_DIR_ENV = "CODEVISOR_AGY_GEMINI_DIR"

/// What makes agy keep its sign-in in a file: its SSH detection.
export const AGY_FILE_TOKENS_ENV = { SSH_CLIENT: "127.0.0.1 0 0" }

/// agy's arguments and environment for an account's process environment. A
/// managed account (one with its own data root) always reads its file
/// sign-in; the user's own agy keeps its Keychain one.
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
    // Codevisor owns updates (the harness catalog's `agy update`).
    env: {
      ...rest,
      ...(geminiDir === undefined ? {} : AGY_FILE_TOKENS_ENV),
      AGY_CLI_DISABLE_AUTO_UPDATE: "true"
    },
    geminiDir
  }
}

/// `agy models`: listing models needs a sign-in, so its outcome is the
/// probe.
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

/// A terminal agy's TUI runs in.
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

/// What a terminal answers when agy asks about it (device attributes, the
/// cursor, colors). The TUI waits for these before it draws.
const replies: ReadonlyArray<readonly [string, string]> = [
  ["\x1b[>c", "\x1b[>1;10;0c"],
  ["\x1b[>0c", "\x1b[>1;10;0c"],
  ["\x1b[c", "\x1b[>1;10;0c"],
  ["\x1b[6n", "\x1b[1;1R"],
  ["\x1b]10;?", "\x1b]10;rgb:ffff/ffff/ffff\x1b\\"],
  ["\x1b]11;?", "\x1b]11;rgb:0000/0000/0000\x1b\\"]
]

const ANSI =
  // oxlint-disable-next-line no-control-regex -- matches ESC/BEL deliberately to strip agy's escape sequences
  /\x1b\[[0-9;?>]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][0-9A-Za-z]|\x1b[=>]/g

/// The sign-in link, from the hyperlink agy draws around it. Only a
/// finished hyperlink counts: the link arrives over several writes, and the
/// address as printed wraps across lines, so anything less is a truncated
/// link Google rejects (`invalid_request`).
export const signInUrl = (screen: string): string | undefined =>
  // oxlint-disable-next-line no-control-regex -- an OSC 8 hyperlink is delimited by ESC/BEL
  /\x1b\]8;[^;]*;(https:\/\/accounts\.google\.com\/[^\x07\x1b]+)(?:\x07|\x1b\\)/.exec(screen)?.[1]

/// Why agy closed before it showed a link: the line that says what failed.
const failure = (screen: string): string | undefined =>
  screen
    .replace(ANSI, "")
    .split(/\r?\n|\r/)
    .map((line) => line.trim())
    .find((line) => /invalid|failed|error|denied|expired/i.test(line))

/// Google's verdict on a code agy sent, when it refused one. Only OAuth's own
/// error codes count: once signed in, agy goes on to its first-run screens,
/// whose theme previews show sample "error" lines.
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
  /// Sends the code the callback page showed; settles once agy holds a
  /// sign-in (or reported that it couldn't).
  readonly submit: (code: string) => Promise<void>
  readonly cancel: () => void
}

export interface AgyLoginOptions {
  readonly spawn: AgyTerminalSpawner
  readonly command: string
  readonly cwd: string
  /// The account's process environment (see agyAccountLaunch).
  readonly env: NodeJS.ProcessEnv
  /// Whether agy now holds a sign-in (`agy models` against the same root).
  readonly signedIn: () => Promise<boolean>
  /// Waits between sign-in checks once a code was sent.
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
      // The first method, Google OAuth, is already highlighted.
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

/* v8 ignore start -- a live pseudo-terminal; tests drive startAgyLogin over fake terminals. */
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
      } catch {
        // Already gone.
      }
    }
  }
}
/* v8 ignore stop */
