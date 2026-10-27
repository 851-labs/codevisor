import { describe, expect, it } from "vitest"

import {
  bootstrapMachine,
  bootstrapScript,
  DEFAULT_INSTALL_URL,
  startServerScript
} from "./bootstrap.js"
import { makeFakeSandboxProvider } from "./fake-provider.js"
import { readAccountValues, readProfileOptions } from "./options.js"
import { SandboxProviderError, isSandboxProviderId } from "./provider.js"

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
    expect(run?.request.script).toContain(
      `curl -fsSL '${DEFAULT_INSTALL_URL}' -o "$installer"\nsh "$installer"`
    )
    expect(run?.request.script).toContain(`auth login --invite - --name 'Ada'\\''s box'`)
  })

  it("streams the install's output as it runs, after a booting machine reports its boot", async () => {
    const provider = makeFakeSandboxProvider({
      boots: true,
      streams: true,
      onExec: () => ({ exitCode: 0, stdout: "installed\n", stderr: "" })
    })
    const events: string[] = []
    const created = await provider.create(
      { name: "box", tags: { owner: "o", machine: "m" } },
      { size: "small" },
      {
        stage: (stage) => events.push(`stage ${stage}`),
        log: (line) => events.push(line),
        output: () => undefined
      }
    )

    await bootstrapMachine(
      provider,
      created.providerMachineId,
      { inviteCode: invite, machineName: "box" },
      (stream, text) => events.push(`${stream} ${text}`)
    )

    expect(provider.provisionStages).toEqual(["create", "boot"])
    expect(events).toEqual(["stage boot", "Booting fake-1", "stdout installed\n"])
  })

  it("lets a fake provider prepare an image first and create machines that already have Codevisor", async () => {
    const provider = makeFakeSandboxProvider({ prepares: true })
    const events: string[] = []
    const progress = {
      stage: (stage: string) => events.push(`stage ${stage}`),
      log: (line: string) => events.push(line),
      output: () => undefined
    }
    const plan = await provider.plan?.({ size: "small" })

    await provider.prepare?.(
      { size: "small" },
      { stages: ["create"], preinstalled: true },
      progress
    )
    await provider.prepare?.(
      { size: "small" },
      plan ?? { stages: [], preinstalled: false },
      progress
    )
    const created = await provider.create(
      { name: "box", tags: { owner: "o", machine: "m" } },
      { size: "small" }
    )

    expect(plan).toEqual({ stages: ["image", "create"], preinstalled: true })
    expect(events).toEqual(["stage image", "Preparing the fake image"])
    expect(created.preinstalled).toBe(true)
  })

  it("opens the app after starting the server when the machine has one", () => {
    expect(startServerScript()).toContain(
      'if [ -x "$home/.codevisor/open-app" ]; then "$home/.codevisor/open-app"; fi'
    )
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
})

describe("profile options", () => {
  it("fills defaults and keeps what the profile sets", () => {
    const { definition } = makeFakeSandboxProvider()

    expect(readProfileOptions(definition, {})).toEqual({ size: "small" })
    expect(readProfileOptions(definition, { size: "large" })).toEqual({ size: "large" })
    expect(readAccountValues(definition, { apiKey: " key " })).toEqual({ apiKey: "key" })
  })

  it("rejects values of the wrong type with the field's label", () => {
    const { definition } = makeFakeSandboxProvider()

    expect(() => readProfileOptions(definition, { size: 3 })).toThrow("Size must be text")
  })

  it("recognizes provider ids", () => {
    expect(["e2b", "modal", "tart", "aws", 1].map(isSandboxProviderId)).toEqual([
      true,
      true,
      true,
      false,
      false
    ])
  })
})

describe("fake provider", () => {
  it("tracks machines by owner through create, status, list and destroy", async () => {
    const provider = makeFakeSandboxProvider({ id: "modal", platform: "darwin" })
    const tags = { owner: "device-a", machine: "m1" }

    const created = await provider.create({ name: "box", tags }, { size: "small" })
    await provider.create(
      { name: "other", tags: { owner: "device-b", machine: "m2" } },
      { size: "small" }
    )

    expect(created).toEqual({ providerMachineId: "fake-1", platform: "darwin" })
    expect(await provider.status("fake-1")).toEqual({ state: "running" })
    expect(await provider.list("device-a")).toEqual([{ providerMachineId: "fake-1", tags }])

    await provider.destroy("fake-1")

    expect(await provider.status("fake-1")).toEqual({ state: "gone" })
    expect(await provider.list("device-a")).toEqual([])
  })

  it("resumes a stopped machine only when asked to be resumable", async () => {
    const resumable = makeFakeSandboxProvider({ resumable: true })
    await resumable.create({ name: "box", tags: { owner: "o", machine: "m" } }, { size: "small" })
    const machine = resumable.machines.get("fake-1")
    if (machine !== undefined) machine.state = "stopped"

    await resumable.resume?.("fake-1")
    await resumable.resume?.("missing")

    expect(await resumable.status("fake-1")).toEqual({ state: "running" })
    expect(makeFakeSandboxProvider().resume).toBeUndefined()
  })

  it("defaults to a Linux e2b-shaped provider", async () => {
    const provider = makeFakeSandboxProvider()
    const created = await provider.create(
      { name: "box", tags: { owner: "o", machine: "m" } },
      { size: "small" }
    )

    expect([provider.definition.id, created.platform]).toEqual(["e2b", "linux"])
  })
})
