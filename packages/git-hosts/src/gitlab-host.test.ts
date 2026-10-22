import { readFileSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { gitlabHost } from "./gitlab-host.js"
import { fakeCli, testTempDir } from "./test-support.js"

const gitlab = gitlabHost()

describe("gitlabHost", () => {
  it("signs in with glab's device flow, which also sets up git", async () => {
    const log = join(testTempDir("codevisor-glab-log-"), "calls")
    const glab = fakeCli(
      "glab",
      `echo "$* browser=$GLAB_BROWSER updates=$GLAB_CHECK_UPDATE" >> '${log}'
case "$1 $2" in
  "auth status") echo "Logged in to gitlab.com" >&2; exit 0 ;;
  "auth login")
    echo "! One-time code: GL12-AB34"
    echo "Open https://gitlab.com/oauth/device to continue."
    exit 0 ;;
  "--version ") echo "glab 1.124.0 (abc123)" ;;
esac`
    )
    const codes: Array<string> = []

    const login = gitlab.login("gitlab.com", glab.env, (code) => codes.push(code.userCode))

    expect(await login.finished).toEqual({ signedIn: true })
    expect(codes).toEqual(["GL12-AB34"])
    expect(await gitlab.authStatus("gitlab.com", glab.env)).toEqual({
      cliInstalled: true,
      signedIn: true
    })
    expect(await gitlab.detect(glab.env)).toEqual({ path: glab.path, version: "1.124.0" })
    expect(gitlab.setUpGitCredentials).toBeUndefined()
    expect(readFileSync(log, "utf8").trim().split("\n").slice(0, 2)).toEqual([
      "auth login --hostname gitlab.com --device --git-protocol https --setup-git-credential-helper browser=true updates=false",
      "auth status --hostname gitlab.com browser=true updates=false"
    ])
  })
})
