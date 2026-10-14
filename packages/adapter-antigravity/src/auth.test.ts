import { afterEach, describe, expect, it, vi } from "vitest"

import {
  agyAccountLaunch,
  agyAuthInspection,
  AGY_GEMINI_DIR_ENV,
  signInUrl,
  startAgyLogin,
  type AgyLoginOptions
} from "./auth.js"
import { fakeTerminalSpawner } from "./test-support.js"

const SIGN_IN_URL =
  "https://accounts.google.com/o/oauth2/auth?client_id=1&redirect_uri=https%3A%2F%2Fantigravity.google%2Foauth-callback"
const MENU =
  "\x1b[1m Select login method:\x1b[0m\r\n > 1. Google OAuth\r\n2. Use a Google Cloud project"
const LINK = `Open the URL below in your browser:\r\n \x1b]8;id=abc;${SIGN_IN_URL}\x07${SIGN_IN_URL.slice(0, 40)}\x1b]8;;\x07`
const MANAGED = { HOME: "/home/me", [AGY_GEMINI_DIR_ENV]: "/profile/gemini" }

afterEach(() => {
  vi.useRealTimers()
})

describe("Antigravity accounts", () => {
  it("points a managed account at its own data root and file sign-in", () => {
    expect(agyAccountLaunch(MANAGED)).toEqual({
      args: ["--gemini_dir=/profile/gemini"],
      env: { HOME: "/home/me", SSH_CLIENT: "127.0.0.1 0 0", AGY_CLI_DISABLE_AUTO_UPDATE: "true" },
      geminiDir: "/profile/gemini"
    })
    expect(agyAccountLaunch({ HOME: "/home/me", [AGY_GEMINI_DIR_ENV]: "" })).toEqual({
      args: [],
      env: { HOME: "/home/me", AGY_CLI_DISABLE_AUTO_UPDATE: "true" },
      geminiDir: undefined
    })
  })

  it("reads the sign-in from whether agy will list models", () => {
    expect(agyAuthInspection({ code: 0, stdout: "m  M", stderr: "" })).toEqual({
      state: "authenticated",
      methods: [],
      canLogout: true
    })
    expect(
      agyAuthInspection({
        code: 1,
        stdout: "",
        stderr:
          "Fetching available models...\nError: Please sign in to view available models. Launch the CLI without arguments to sign in."
      })
    ).toMatchObject({ state: "unauthenticated", canLogout: false })
    expect(
      agyAuthInspection({
        code: 1,
        stdout: "",
        stderr: "Fetching available models...\nError: quota project missing"
      })
    ).toEqual({
      state: "error",
      methods: [],
      canLogout: false,
      detail: "Error: quota project missing"
    })
    expect(agyAuthInspection({ code: 2, stdout: "", stderr: "" })).toMatchObject({
      detail: "agy exited with status 2"
    })
  })

  it("takes the sign-in link only from agy's finished hyperlink", () => {
    expect(signInUrl(LINK)).toBe(SIGN_IN_URL)
    expect(signInUrl(`\x1b]8;id=abc;${SIGN_IN_URL}\x1b\\`)).toBe(SIGN_IN_URL)
    expect(signInUrl(`\x1b[2m${SIGN_IN_URL}\x1b[0m\r\n`)).toBeUndefined()
    expect(signInUrl(`\x1b]8;id=abc;${SIGN_IN_URL}`)).toBeUndefined()
    expect(signInUrl("Welcome")).toBeUndefined()
  })
})

const login = (options: Partial<AgyLoginOptions> = {}) => {
  const tty = fakeTerminalSpawner()
  const signedIn = vi.fn(async () => false)
  const wait = vi.fn(async () => undefined)
  const started = startAgyLogin({
    spawn: tty.spawn,
    command: "/bin/agy",
    cwd: "/home/me",
    env: MANAGED,
    signedIn,
    wait,
    ...options
  })
  return { ...tty, started, signedIn, wait }
}

const spawnedTerminal = (tty: { ready: () => Promise<void> }) => tty.ready()

describe("Antigravity sign-in", () => {
  it("answers the terminal, chooses Google OAuth and surfaces the sign-in link", async () => {
    const tty = login()
    await spawnedTerminal(tty)
    expect(tty.requests[0]).toEqual({
      command: "/bin/agy",
      args: ["--gemini_dir=/profile/gemini"],
      cwd: "/home/me",
      env: {
        HOME: "/home/me",
        SSH_CLIENT: "127.0.0.1 0 0",
        AGY_CLI_DISABLE_AUTO_UPDATE: "true",
        TERM: "xterm-256color"
      }
    })
    tty.terminal.draw("\x1b[>c\x1b[6n\x1b]10;?\x1b\\\x1b]11;?\x1b\\")
    expect(tty.terminal.written).toEqual([
      "\x1b[>1;10;0c",
      "\x1b[1;1R",
      "\x1b]10;rgb:ffff/ffff/ffff\x1b\\",
      "\x1b]11;rgb:0000/0000/0000\x1b\\"
    ])
    tty.terminal.draw(MENU)
    tty.terminal.draw(MENU)
    expect(tty.terminal.written.filter((data) => data === "\r")).toHaveLength(1)
    tty.terminal.draw(LINK)
    const { url } = await tty.started
    expect(url).toBe(SIGN_IN_URL)
  })

  it("waits for a link agy writes in pieces", async () => {
    const tty = login()
    await spawnedTerminal(tty)
    const cut = LINK.indexOf("redirect_uri")
    tty.terminal.draw(LINK.slice(0, cut))
    tty.terminal.draw(LINK.slice(cut))
    expect((await tty.started).url).toBe(SIGN_IN_URL)
  })

  it("finishes once agy holds the sign-in the pasted code made", async () => {
    const tty = login()
    await spawnedTerminal(tty)
    tty.terminal.draw(LINK)
    const flow = await tty.started
    tty.signedIn.mockResolvedValueOnce(false).mockResolvedValueOnce(true)
    await flow.submit("  4/0Abc  ")
    expect(tty.terminal.written.at(-1)).toBe("4/0Abc\r")
    expect(tty.signedIn).toHaveBeenCalledTimes(2)
    expect(tty.terminal.killed).toBe(true)
  })

  it("reports what agy said about a code it rejected", async () => {
    const tty = login()
    await spawnedTerminal(tty)
    tty.terminal.draw(`Paste code: ${LINK}`)
    const flow = await tty.started
    tty.wait.mockImplementationOnce(async () => {
      tty.terminal.draw("\r\n\x1b[31mError: invalid_grant\x1b[0m\r\n")
    })
    await expect(flow.submit("bad")).rejects.toThrow(
      "Google didn't accept that code (invalid_grant). Start again and paste the new code."
    )
    expect(tty.terminal.killed).toBe(true)
  })

  it("isn't fooled by the sample errors in agy's theme picker", async () => {
    const tty = login()
    await spawnedTerminal(tty)
    tty.terminal.draw(LINK)
    const flow = await tty.started
    tty.wait.mockImplementationOnce(async () => {
      tty.terminal.draw(
        "tokyo night│   ⚙ tool: write_file main.go││   ✗ error: compilation failed││   ⚠ warning: deprecation warning│"
      )
    })
    tty.signedIn.mockResolvedValueOnce(true)
    await expect(flow.submit("4/0Abc")).resolves.toBeUndefined()
  })

  it("gives up on a code agy never accepts", async () => {
    const tty = login({ checks: 2 })
    await spawnedTerminal(tty)
    tty.terminal.draw(LINK)
    const flow = await tty.started
    await expect(flow.submit("code")).rejects.toThrow("didn't accept that code")
    expect(tty.signedIn).toHaveBeenCalledTimes(2)
  })

  it("stops checking once agy has exited", async () => {
    const tty = login()
    await spawnedTerminal(tty)
    tty.terminal.draw(LINK)
    const flow = await tty.started
    tty.terminal.exit(0)
    await expect(flow.submit("code")).rejects.toThrow("didn't accept that code")
    expect(tty.signedIn).toHaveBeenCalledTimes(1)
  })

  it("can be cancelled while waiting on the code", async () => {
    const tty = login()
    await spawnedTerminal(tty)
    tty.terminal.draw(LINK)
    ;(await tty.started).cancel()
    expect(tty.terminal.killed).toBe(true)
  })

  it("fails when agy closes before it shows a link", async () => {
    const tty = login()
    await spawnedTerminal(tty)
    tty.terminal.exit(1)
    await expect(tty.started).rejects.toThrow("closed before it showed a sign-in link")
    expect(tty.terminal.killed).toBe(true)
  })

  it("fails with agy's own message when it reports an error first", async () => {
    const tty = login()
    await spawnedTerminal(tty)
    tty.terminal.draw("OAuth failed: network unreachable\r\n")
    tty.terminal.exit(1)
    await expect(tty.started).rejects.toThrow("OAuth failed: network unreachable")
  })

  it("gives up when no link appears in time", async () => {
    vi.useFakeTimers()
    const tty = login({ urlDeadlineMs: 1_000 })
    const failed = expect(tty.started).rejects.toThrow("didn't show a sign-in link in time")
    await vi.advanceTimersByTimeAsync(999)
    expect(tty.terminal.killed).toBe(false)
    await vi.advanceTimersByTimeAsync(1)
    await failed
    expect(tty.terminal.killed).toBe(true)
  })

  it("only signs in accounts Codevisor manages", async () => {
    await expect(login({ env: { HOME: "/home/me" } }).started).rejects.toThrow(
      "Run agy in a terminal"
    )
  })
})
