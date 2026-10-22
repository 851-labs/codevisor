import { readFileSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import type { DeviceCode } from "./git-host.js"
import { githubHost } from "./github-host.js"
import { emptyEnv, fakeCli, testTempDir } from "./test-support.js"

const recordingGh = (script: string) => {
  const log = join(testTempDir("codevisor-gh-log-"), "calls")
  const cli = fakeCli(
    "gh",
    `echo "$* browser=$GH_BROWSER updates=$GH_NO_UPDATE_NOTIFIER config=$GH_CONFIG_DIR" >> '${log}'\n${script}`
  )
  return { ...cli, calls: () => readFileSync(log, "utf8").trim().split("\n") }
}

const github = githubHost()

describe("githubHost", () => {
  it("finds gh on PATH with its version", async () => {
    const gh = recordingGh(`echo "gh version 2.98.0 (2026-08-20)"`)

    expect(await github.detect(gh.env)).toEqual({ path: gh.path, version: "2.98.0" })
    expect(await github.detect(emptyEnv())).toBeUndefined()
    expect(await github.detect({ HOME: String(gh.env.HOME) })).toBeUndefined()
  })

  it("reports the signed-in account, a signed-out CLI, and a missing one", async () => {
    const signedIn = recordingGh(`echo "✓ Logged in to github.com account octocat (keyring)"`)
    const signedOut = recordingGh(`echo "You are not logged into any GitHub hosts." >&2; exit 1`)

    expect(await github.authStatus("github.com", signedIn.env)).toEqual({
      cliInstalled: true,
      signedIn: true,
      account: "octocat"
    })
    expect(signedIn.calls()).toEqual([
      `auth status --hostname github.com browser=true updates=1 config=${String(signedIn.env.GH_CONFIG_DIR)}`
    ])
    expect(await github.authStatus("github.com", signedOut.env)).toEqual({
      cliInstalled: true,
      signedIn: false
    })
    expect(await github.authStatus("github.com", emptyEnv())).toEqual({
      cliInstalled: false,
      signedIn: false
    })
  })

  it("signs in through gh's web device flow", async () => {
    const gh = recordingGh(`
echo "! First copy your one-time code: AB12-CD34" >&2
echo "Open this URL to continue in your web browser: https://github.com/login/device" >&2
sleep 0.1
echo "Authentication complete. Second code: ZZ99-YY88" >&2
exit 0`)
    const codes: Array<DeviceCode> = []

    const login = github.login("github.com", gh.env, (code) => codes.push(code))

    expect(await login.finished).toEqual({ signedIn: true })
    expect(codes).toEqual([
      { userCode: "AB12-CD34", verificationUrl: "https://github.com/login/device" }
    ])
    expect(gh.calls()[0]).toMatch(
      /^auth login --web --hostname github\.com --git-protocol https --skip-ssh-key browser=true/
    )
  })

  it("explains a failed or impossible sign-in", async () => {
    const failing = recordingGh(`echo "error connecting to github.com" >&2\nexit 1`)

    expect(await github.login("github.com", failing.env, () => undefined).finished).toEqual({
      signedIn: false,
      message: "gh sign-in failed (exit 1).\nerror connecting to github.com"
    })
    const missing = github.login("github.com", emptyEnv(), () => undefined)
    missing.cancel()
    expect(await missing.finished).toEqual({
      signedIn: false,
      message: "gh isn't installed on this machine"
    })
  })

  it("stops a sign-in that's still waiting", async () => {
    const gh = recordingGh("exec sleep 30")
    const login = github.login("github.com", gh.env, () => undefined)

    login.cancel()

    expect(await login.finished).toMatchObject({ signedIn: false })
  })

  it("makes git use gh for the host's credentials", async () => {
    const gh = recordingGh("exit 0")

    await github.setUpGitCredentials?.("github.com", gh.env)
    await github.setUpGitCredentials?.("github.com", emptyEnv())

    expect(gh.calls()).toEqual([
      `auth setup-git --hostname github.com browser=true updates=1 config=${String(gh.env.GH_CONFIG_DIR)}`
    ])
  })
})
