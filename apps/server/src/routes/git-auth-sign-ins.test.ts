import { existsSync, readFileSync, realpathSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { jsonRequest } from "../test-support.js"
import {
  fakeGhRelease,
  isolatedGitEnv,
  startServer,
  type TestServer
} from "./project-setup-test-support.js"

const tokenGh = `case "$1 $2" in
  "auth login") read -r token; echo "$token" > "$HOME/token"; echo "$*" > "$HOME/login-args" ;;
  "auth setup-git") echo "$*" > "$HOME/setup-git-args" ;;
  "auth status") [ -f "$HOME/token" ] && echo "Logged in to github.com account octocat" && exit 0; exit 1 ;;
  *) exit 1 ;;
esac`

const rejectingGh = `case "$1 $2" in
  "auth login") read -r token; echo "error validating token $token: HTTP 401: Bad credentials" >&2; exit 1 ;;
  *) exit 1 ;;
esac`

const copySignIn = (server: TestServer, host = "github.com") =>
  jsonRequest(server, "/v1/git/auth/sign-ins", {
    body: JSON.stringify({ signIns: [{ host, token: "gho_copied" }] }),
    method: "PUT"
  })

describe("taking a git sign-in copied from another machine", () => {
  it("installs GitHub CLI, signs it and git in with the token, and puts gh on the agent's PATH", async () => {
    const release = await fakeGhRelease(tokenGh)
    const env = isolatedGitEnv()
    const home = String(env.HOME)
    const { server } = await startServer(env, release.gitHosts)

    const copied = await copySignIn(server)
    const status = await jsonRequest(server, "/v1/git/auth/status?host=github.com")

    expect(copied.body).toEqual({
      applied: [{ host: "github.com", signedIn: true, account: "octocat" }]
    })
    expect(readFileSync(join(home, "token"), "utf8")).toBe("gho_copied\n")
    expect(readFileSync(join(home, "login-args"), "utf8")).not.toContain("gho_copied")
    expect(readFileSync(join(home, "setup-git-args"), "utf8")).toContain("--hostname github.com")
    expect(realpathSync(join(home, ".local", "bin", "gh"))).toBe(
      realpathSync(join(release.toolsDir, "bin", "gh"))
    )
    expect(status.body).toMatchObject({ signedIn: true, copiesToSandboxes: true })
  })

  it("reports a token the host rejects without repeating it, and a host it can't sign in to", async () => {
    const release = await fakeGhRelease(rejectingGh)
    const env = isolatedGitEnv()
    const { server } = await startServer(env, release.gitHosts)

    const rejected = await copySignIn(server)
    const unsupported = await copySignIn(server, "git.acme.dev")

    expect(rejected.body).toEqual({
      applied: [
        {
          host: "github.com",
          signedIn: false,
          message: "error validating token [token]: HTTP 401: Bad credentials"
        }
      ]
    })
    expect(existsSync(join(String(env.HOME), ".local", "bin", "gh"))).toBe(false)
    expect(unsupported.body).toEqual({
      applied: [
        {
          host: "git.acme.dev",
          signedIn: false,
          message: "Copying a sign-in for git.acme.dev isn't supported yet"
        }
      ]
    })
  })
})
