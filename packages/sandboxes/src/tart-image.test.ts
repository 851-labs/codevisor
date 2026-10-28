import { describe, expect, it } from "vitest"

import type { ProvisionPlan, ProvisionProgress } from "./provider.js"
import { fakeTart, result } from "./tart-test-support.js"
import {
  IMAGE_PREFIX,
  makeTartProvider,
  TOOLS_PREFIX,
  vmName,
  type TartImageRecipe
} from "./tart.js"

const spec = { name: "box", tags: { owner: "device-a", machine: "m1" } }
const baseImage = "ghcr.io/cirruslabs/macos-tahoe-base:latest"
const options = { image: baseImage, cpu: 4, memoryGiB: 8 }
const recipe: TartImageRecipe = {
  appPath: "/Builds/Debug/Codevisor (dev).app",
  fingerprint: "app-1+server-1",
  agentCommands: ["npm install -g @openai/codex"],
  installUrl: "http://192.168.1.2:4000/install.sh",
  installEnvironment: { CODEVISOR_VERSION: "dev" },
  development: { instanceId: "dev-sandbox", serverPort: 49361 }
}
const withImage: ProvisionPlan = { stages: ["image", "create", "boot"], preinstalled: true }

const recorder = () => {
  const events: string[] = []
  const progress: ProvisionProgress = {
    stage: (stage) => events.push(`stage ${stage}`),
    log: (line) => events.push(line),
    output: (stream, text) => events.push(`${stream} ${text}`)
  }
  return { events, progress }
}

const releaseRecipe: TartImageRecipe = {
  appPath: recipe.appPath,
  fingerprint: recipe.fingerprint,
  agentCommands: recipe.agentCommands
}

const images = (value: TartImageRecipe = recipe) => ({ recipe: () => Promise.resolve(value) })

const toolsLayerOf = (tart: ReturnType<typeof fakeTart>): string =>
  tart.vms.find((vm) => vm.Name.startsWith(TOOLS_PREFIX))?.Name ?? ""

const imageNameOf = async (tart: ReturnType<typeof fakeTart>): Promise<string> => {
  const provider = makeTartProvider(tart.host, images())
  const prepared = await provider.prepare?.(options, withImage, recorder().progress)
  return String(prepared?.["preparedImage"] ?? "")
}

describe("Tart macOS image", () => {
  it("plans an image step only while the prepared image is missing", async () => {
    const tart = fakeTart({ onScript: () => result("ready\n") })
    const provider = makeTartProvider(tart.host, images())

    expect(await provider.plan?.(options)).toEqual(withImage)
    await provider.prepare?.(options, withImage, recorder().progress)
    expect(await provider.plan?.(options)).toEqual({
      stages: ["create", "boot"],
      preinstalled: true
    })
  })

  it("installs Tart as its own first step on a Mac that doesn't have it yet", async () => {
    const tart = fakeTart({ installed: false, onScript: () => result("ready\n") })
    const provider = makeTartProvider(tart.host, images())
    const { events, progress } = recorder()

    const plan = await provider.plan?.(options)
    const availability = await provider.availability?.(options)
    const listed = await provider.list("device-a")
    await provider.prepare?.(options, plan ?? withImage, progress)

    expect(plan).toEqual({ stages: ["tart", "image", "create", "boot"], preinstalled: true })
    expect(availability).toBeUndefined()
    expect(listed).toEqual([])
    expect(events.slice(0, 3)).toEqual(["stage tart", "Installed Tart", "stage image"])
    expect(tart.commands[0]).toBe("install")
  })

  it("builds a tools layer from the base image, then a Codevisor layer on top, then clones VMs from it", async () => {
    const scripts: string[] = []
    const tart = fakeTart({
      vms: [{ Name: `${IMAGE_PREFIX}older`, State: "stopped", OS: "darwin" }],
      onScript: (script, runOptions) => {
        scripts.push(script)
        runOptions?.onOutput?.("stdout", "==> Installing Codevisor (dev).app\n")
        return result("")
      }
    })
    const provider = makeTartProvider(tart.host, images())
    const { events, progress } = recorder()

    const prepared = await provider.prepare?.(options, withImage, progress)
    const image = String(prepared?.["preparedImage"] ?? "")
    const created = await provider.create(spec, prepared ?? options)

    const tools = toolsLayerOf(tart)
    expect(image).toMatch(new RegExp(`^${IMAGE_PREFIX}[0-9a-f]{16}$`))
    expect(tools).toMatch(new RegExp(`^${TOOLS_PREFIX}[0-9a-f]{16}$`))
    expect(events[0]).toBe("stage image")
    expect(events).toContain("stdout ==> Installing Codevisor (dev).app\n")
    expect(events).toContain(`Deleting the older image ${IMAGE_PREFIX}older`)
    expect(tart.commands).toContain(`clone ${baseImage} ${tools}-building`)
    expect(tart.commands).toContain(`rename ${tools}-building ${tools}`)
    expect(tart.commands).toContain(`clone ${tools} ${image}-building`)
    expect(tart.commands).toContain(
      `copyIn ${image}-building /Builds/Debug/Codevisor (dev).app /Applications`
    )
    expect(tart.commands).toContain(`rename ${image}-building ${image}`)
    expect(scripts[0]).toContain("npm install -g @openai/codex")
    expect(scripts[0]).not.toContain("/Applications")
    expect(scripts[1]).toContain("app='/Applications/Codevisor (dev).app'")
    expect(created).toEqual({
      providerMachineId: vmName(spec),
      platform: "darwin",
      preinstalled: true
    })
    expect(tart.vms.map((vm) => vm.Name)).toEqual([tools, image, vmName(spec)])
  })

  it("rebuilds only the Codevisor layer when Codevisor updates", async () => {
    const tart = fakeTart({ onScript: () => result("") })
    const before = makeTartProvider(tart.host, images())
    const after = makeTartProvider(tart.host, images({ ...recipe, fingerprint: "app-2+server-2" }))

    const first = await before.prepare?.(options, withImage, recorder().progress)
    const tools = toolsLayerOf(tart)
    const cloned = tart.commands.length
    const second = await after.prepare?.(options, withImage, recorder().progress)

    const rebuild = tart.commands.slice(cloned)
    expect(second?.["preparedImage"]).not.toBe(first?.["preparedImage"])
    expect(rebuild.filter((command) => command.startsWith("clone "))).toEqual([
      `clone ${tools} ${String(second?.["preparedImage"])}-building`
    ])
    expect(tart.vms.map((vm) => vm.Name)).toEqual([tools, second?.["preparedImage"]])
  })

  it("lets a second sandbox wait for the image another one is preparing", async () => {
    const tart = fakeTart({ onScript: () => result("") })
    const provider = makeTartProvider(tart.host, images())
    const second = recorder()

    const [first, next] = await Promise.all([
      provider.prepare?.(options, withImage, recorder().progress),
      provider.prepare?.(options, withImage, second.progress)
    ])

    expect(next?.["preparedImage"]).toBe(first?.["preparedImage"])
    expect(
      tart.commands.filter((command) => command.startsWith(`clone ${baseImage}`))
    ).toHaveLength(1)
    expect(second.events).toEqual([
      "stage image",
      "Waiting for another sandbox that's preparing this image"
    ])
  })

  it("reuses a prepared image without starting a step the plan didn't list", async () => {
    const tart = fakeTart({ onScript: () => result("") })
    const image = await imageNameOf(tart)
    const provider = makeTartProvider(tart.host, images())
    const { events, progress } = recorder()

    await provider.prepare?.(options, { stages: ["create", "boot"], preinstalled: true }, progress)

    expect(events).toEqual([`${image} is already prepared`])
  })

  it("deletes the half-built VM and reports the end of the setup output when setup fails", async () => {
    const tart = fakeTart({
      onScript: (script) =>
        script.includes("/Applications")
          ? {
              exitCode: 1,
              stdout: "==> Installing the Codevisor server\n",
              stderr: "curl: (7) refused\n"
            }
          : result("")
    })
    const provider = makeTartProvider(tart.host, images(releaseRecipe))

    await expect(provider.prepare?.(options, withImage, recorder().progress)).rejects.toThrow(
      "Setting up macOS failed (exit 1):\n==> Installing the Codevisor server\ncurl: (7) refused"
    )
    expect(tart.vms.map((vm) => vm.Name)).toEqual([toolsLayerOf(tart)])
  })

  it("stops and deletes the half-built VM when the app can't be copied in", async () => {
    const tart = fakeTart({ copyExit: 2 })
    const provider = makeTartProvider(tart.host, images())

    await expect(provider.prepare?.(options, withImage, recorder().progress)).rejects.toThrow(
      "Copying Codevisor into the macOS image failed (exit 2):\ntar: broken pipe"
    )
    expect(tart.vms.map((vm) => vm.Name)).toEqual([toolsLayerOf(tart)])
  })

  it("keeps cloning the profile's image when there is no app to install, it isn't macOS, or it's already prepared", async () => {
    const tart = fakeTart({})
    const bare = makeTartProvider(tart.host, { recipe: () => Promise.resolve(undefined) })
    const pinned = { ...options, preparedImage: "my-image" }
    const prepared = makeTartProvider(tart.host, images())
    const preparedName = `${IMAGE_PREFIX}0123456789abcdef`

    expect(await bare.plan?.(options)).toEqual({ stages: ["create", "boot"], preinstalled: false })
    expect((await bare.prepare?.(options, withImage, recorder().progress))?.["preparedImage"]).toBe(
      baseImage
    )
    expect(await prepared.plan?.(pinned)).toEqual({
      stages: ["create", "boot"],
      preinstalled: false
    })
    expect(await prepared.prepare?.(pinned, withImage, recorder().progress)).toEqual(pinned)
    expect((await prepared.plan?.({ ...options, preparedImage: preparedName }))?.preinstalled).toBe(
      true
    )
    expect(
      await prepared.plan?.({ ...options, image: "ghcr.io/cirruslabs/ubuntu:latest" })
    ).toEqual({ stages: ["create", "boot"], preinstalled: false })
    expect(await makeTartProvider(tart.host).plan?.(options)).toEqual({
      stages: ["create", "boot"],
      preinstalled: false
    })
    expect((await makeTartProvider(tart.host).create(spec, options)).preinstalled).toBe(false)
    expect(tart.commands).toContain(`clone ${baseImage} ${vmName(spec)}`)
  })
})
