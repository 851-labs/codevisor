import { describe, expect, it, onTestFinished, vi } from "vitest"

import { jsonRequest } from "../test-support.js"
import { fakeCli, makeOrigin, startServer } from "./project-setup-test-support.js"

const checkAccess = (server: Awaited<ReturnType<typeof startServer>>["server"], url: string) =>
  jsonRequest(server, "/v1/projects/clone-access", {
    body: JSON.stringify({ url }),
    method: "POST"
  })

const quietCloneLog = (): void => {
  const logged = vi.spyOn(console, "error").mockImplementation(() => undefined)
  onTestFinished(() => logged.mockRestore())
}

describe("project clone access", () => {
  it("reports a repository the machine can reach, over either transport", async () => {
    const origin = await makeOrigin()
    const env = fakeCli("fake-ssh", 'for last; do :; done\ncd / && exec sh -c "$last"')
    const { server } = await startServer({ ...env, GIT_SSH_COMMAND: "fake-ssh" })
    quietCloneLog()

    const viaFile = await checkAccess(server, `file://${origin}`)
    const viaSsh = await checkAccess(server, `https://localhost${origin}`)

    expect(viaFile).toMatchObject({ status: 200, body: { ok: true } })
    expect(viaSsh).toMatchObject({ status: 200, body: { ok: true } })
  })

  it("reports why a machine without credentials can't reach a private repository", async () => {
    const env = fakeCli(
      "fake-ssh",
      'echo "git@localhost: Permission denied (publickey)." >&2\nexit 255'
    )
    const { server } = await startServer({ ...env, GIT_SSH_COMMAND: "fake-ssh" })
    quietCloneLog()

    const denied = await checkAccess(server, "https://localhost/acme/private.git")
    const invalid = await checkAccess(server, "not a url")

    expect(denied).toMatchObject({ status: 200, body: { ok: false, code: "auth_failed" } })
    expect(invalid).toMatchObject({ status: 200, body: { ok: false, code: "invalid_url" } })
  })
})
