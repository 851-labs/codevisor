import type { ExecRequest } from "@codevisor/sandboxes"
import { describe, expect, it } from "vitest"

import { field } from "../unknown-values.js"
import { ok, OWNER_GIT_SIGN_IN, sandboxHarness } from "./sandbox-test-support.js"

const request = { profileId: "profile-1", projectId: "project-1", name: "Git box" }
const signInsUrl = "/v1/git/auth/sign-ins'"

const isSignInCopy = (curl: ExecRequest): boolean => curl.script.includes(signInsUrl)

const copiedTokens = (curls: ReadonlyArray<ExecRequest>): ReadonlyArray<unknown> =>
  curls.filter(isSignInCopy).flatMap((curl) => {
    const signIns = field(JSON.parse(curl.stdin ?? "{}"), "signIns")
    return Array.isArray(signIns) ? signIns.map((signIn) => field(signIn, "token")) : []
  })

const answering = (applied: unknown) => (curl: ExecRequest) =>
  isSignInCopy(curl) ? ok(JSON.stringify({ applied: [applied] })) : ok()

const cloneRejection = (code: string) => () =>
  Promise.reject(Object.assign(new Error("fatal: raw git output"), { code }))

const failedWith = async (harness: Awaited<ReturnType<typeof sandboxHarness>>) => {
  await harness.machines.create(request)
  await harness.machines.settled()
  return (await harness.machines.list())[0]?.error
}

describe("git sign-ins on a sandbox", () => {
  it("copies the host's GitHub sign-in to a new sandbox and says so in its setup log", async () => {
    const lines: string[] = []
    const harness = await sandboxHarness({
      onCurl: answering({ host: "github.com", signedIn: true, account: "octocat" })
    })

    await harness.machines.create(request, (log) => {
      lines.push(`${log.stage}: ${log.line}`)
      return Promise.resolve()
    })
    await harness.machines.settled()

    expect(copiedTokens(harness.curls)).toEqual([OWNER_GIT_SIGN_IN.token])
    expect(lines).toContain("sync: Signed in to GitHub as octocat, copied from Owner Mac")
    expect((await harness.machines.list())[0]?.state).toBe("ready")
  })

  it("copies a new GitHub sign-in to a running sandbox once, on the next check", async () => {
    let token = "gho_first"
    const harness = await sandboxHarness({
      gitSignIns: () => [{ host: "github.com", token }]
    })
    await harness.machines.create(request)
    await harness.machines.settled()

    await harness.machines.watch()
    token = "gho_second"
    await harness.machines.watch()
    await harness.machines.watch()

    expect(copiedTokens(harness.curls)).toEqual(["gho_first", "gho_second"])
  })

  it("refuses a sandbox for a GitHub project until the host is signed in to GitHub", async () => {
    const harness = await sandboxHarness({ gitSignIns: () => [] })

    await expect(harness.machines.create(request)).rejects.toMatchObject({
      status: 409,
      code: "git_sign_in_required",
      message: expect.stringContaining("Sign in to GitHub on Owner Mac first")
    })
    expect(await harness.machines.list()).toEqual([])
  })

  it("starts a sandbox without a GitHub sign-in for a project hosted elsewhere, noting what it can't do", async () => {
    const lines: string[] = []
    const harness = await sandboxHarness({
      gitSignIns: () => [],
      project: { repoUrl: "https://git.acme.dev/acme/widget.git" }
    })

    await harness.machines.create(request, (log) => {
      lines.push(log.line)
      return Promise.resolve()
    })
    await harness.machines.settled()

    expect((await harness.machines.list())[0]?.state).toBe("ready")
    expect(harness.curls.filter(isSignInCopy)).toEqual([])
    expect(lines).toContain(
      "Owner Mac isn't signed in to GitHub: this sandbox can only read public repositories and can't push"
    )
  })

  it("keeps starting the sandbox when it can't take the sign-in", async () => {
    const harness = await sandboxHarness({
      onCurl: (curl) =>
        isSignInCopy(curl) ? { exitCode: 22, stdout: "", stderr: "curl: (22) 404" } : ok()
    })

    await harness.machines.create(request)
    await harness.machines.settled()

    expect((await harness.machines.list())[0]?.state).toBe("ready")
    expect(harness.logs.join("\n")).toContain("Copying git sign-ins to a sandbox failed")
  })
})

describe("a clone that fails on a sandbox", () => {
  it("names the account that has no access to the repository", async () => {
    const harness = await sandboxHarness({
      onCurl: answering({ host: "github.com", signedIn: true, account: "octocat" })
    })
    harness.controls.answer = cloneRejection("auth_failed")

    expect(await failedWith(harness)).toBe(
      "Couldn't clone 851-labs/codevisor. octocat on GitHub can't open this repository, or it doesn't exist. Check the project's remote URL and that this account has access to it."
    )
  })

  it("says the sign-in didn't work on the sandbox, with the reason", async () => {
    const harness = await sandboxHarness({
      onCurl: answering({ host: "github.com", signedIn: false, message: "bad credentials" })
    })
    harness.controls.answer = cloneRejection("repo_not_found")

    expect(await failedWith(harness)).toBe(
      "Couldn't clone 851-labs/codevisor. The sandbox couldn't sign in to GitHub with Owner Mac's sign-in (bad credentials). Sign in to GitHub on Owner Mac again, then try again."
    )
  })

  it("says a host whose sign-in can't be copied leaves the sandbox signed out", async () => {
    const harness = await sandboxHarness({
      project: { repoUrl: "git@gitlab.com:acme/widget.git" }
    })
    harness.controls.answer = cloneRejection("auth_failed")

    expect(await failedWith(harness)).toBe(
      "Couldn't clone acme/widget. The sandbox isn't signed in to GitLab, so it can only open public repositories. Codevisor can't copy a GitLab sign-in to a sandbox yet."
    )
  })

  it("tells an unreachable git host apart from a sign-in problem", async () => {
    const harness = await sandboxHarness()
    harness.controls.answer = cloneRejection("network")

    expect(await failedWith(harness)).toBe(
      "Couldn't clone 851-labs/codevisor. The sandbox couldn't reach github.com. Check the sandbox's network access, then try again."
    )
  })
})
