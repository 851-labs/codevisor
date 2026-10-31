import { describe, expect, it } from "vitest"

import {
  bootstrapMachine,
  bootstrapScript,
  DEFAULT_INSTALL_URL,
  startServerScript
} from "./bootstrap.js"
import { makeFakeSandboxProvider } from "./fake-provider.js"
import { SandboxProviderError } from "./provider.js"

const invite = "cvi1.aHR0cDovL2Nsb3Vk.secret-token"

describe("bootstrapMachine", () => {
  it("installs with the service and setup steps off, then starts and joins with the invite on stdin", async () => {
    const provider = makeFakeSandboxProvider()

    await bootstrapMachine(provider, "fake-1", { inviteCode: invite, machineName: "Ada's box" })

    const [run] = provider.execs
    expect(run?.request.stdin).toBe(`${invite}\n`)
    expect(run?.request.script).not.toContain(invite)
    expect(run?.request.script).toContain(
      "export CODEVISOR_NO_SETUP=1 CODEVISOR_NO_SERVICE=1 CODEVISOR_INSTALL_SERVER=1"
    )
    expect(run?.request.script).toContain("unset SUDO_USER\n")
    expect(run?.request.script).toContain(
      `curl -fsSL '${DEFAULT_INSTALL_URL}' -o "$installer"\nsh "$installer"`
    )
    expect(run?.request.script).toContain(`auth login --invite - --name 'Ada'\\''s box'`)
  })

  it("streams the install's output as it runs", async () => {
    const provider = makeFakeSandboxProvider({
      onExec: (_machine, request) => {
        request.onOutput?.("stdout", "installed\n")
        return { exitCode: 0, stdout: "installed\n", stderr: "" }
      }
    })
    const events: string[] = []

    await bootstrapMachine(
      provider,
      "fake-1",
      { inviteCode: invite, machineName: "box" },
      (stream, text) => events.push(`${stream} ${text}`)
    )

    expect(events).toEqual(["stdout installed\n"])
  })

  it("gives a small Linux machine swap before installing, so agents don't run it out of memory", () => {
    const lines = bootstrapScript({ inviteCode: invite, machineName: "box" }).split("\n")

    const swap = lines.findIndex((line) => line.includes("swapon /swapfile"))
    const install = lines.findIndex((line) => line.endsWith('sh "$installer"'))
    expect(lines[swap - 1]).toContain(
      `-lt 2097152 ] && [ -z "$(swapon --noheadings 2>/dev/null)" ]`
    )
    expect(lines[swap]).toContain("|| rm -f /swapfile")
    expect(swap).toBeLessThan(install)
  })

  it("skips the installer on a machine whose image already has Codevisor", () => {
    const script = bootstrapScript({ inviteCode: invite, machineName: "box", preinstalled: true })

    expect(script).not.toContain("installer")
    expect(script.split("\n")[1]).toBe("printf '%s\\n' '::codevisor-stage::signIn'")
  })

  it("passes installer environment to the installer and server environment to the start command", () => {
    const script = bootstrapScript({
      inviteCode: invite,
      machineName: "box",
      installUrl: "http://192.168.64.1:4000/install.sh",
      installEnvironment: { CODEVISOR_SERVER_ARCHIVE_BASE: "http://192.168.64.1:4000" },
      serverEnvironment: { CODEVISOR_NET_CA_PEM: "-----BEGIN-----" }
    })

    const lines = script.split("\n")
    expect(lines.find((line) => line.includes(" start "))).toBe(
      `as_server CODEVISOR_NET_CA_PEM='-----BEGIN-----' "$home/.local/bin/codevisor" start </dev/null`
    )
    expect(lines.find((line) => line.endsWith('sh "$installer"'))).toBe(
      `CODEVISOR_SERVER_ARCHIVE_BASE='http://192.168.64.1:4000' sh "$installer"`
    )
    expect(script).toContain("curl -fsSL 'http://192.168.64.1:4000/install.sh' -o")
  })

  it("reports a failed install with the output tail and the invite redacted", async () => {
    const provider = makeFakeSandboxProvider({
      onExec: () => ({ exitCode: 1, stdout: "downloading\n", stderr: `bad invite ${invite}\n` })
    })

    const failure = await bootstrapMachine(provider, "fake-1", {
      inviteCode: invite,
      machineName: "box"
    }).catch((cause: unknown) => cause)

    expect(failure).toBeInstanceOf(SandboxProviderError)
    const message = failure instanceof Error ? failure.message : ""
    expect(message).toContain("failed (exit 1):\ndownloading\nbad invite [invite]")
    expect(message).not.toContain("secret-token")
  })
})

describe("startServerScript", () => {
  it("starts the installed server as its service user without installing or joining", () => {
    const script = startServerScript({ CODEVISOR_NET_CA_PEM: "pem" })

    expect(script).toContain(
      `as_server CODEVISOR_NET_CA_PEM='pem' "$home/.local/bin/codevisor" start`
    )
    expect(script).not.toContain("curl")
    expect(script).not.toContain("auth login")
    expect(startServerScript()).toContain('as_server "$home/.local/bin/codevisor" start')
  })

  it("opens the app after starting the server when the machine has one", () => {
    expect(startServerScript()).toContain(
      'if [ -x "$home/.codevisor/open-app" ]; then "$home/.codevisor/open-app"; fi'
    )
  })
})
