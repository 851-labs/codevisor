import { describe, expect, it } from "vitest"

import type { ProvisionPlan, ProvisionProgress } from "./provider.js"
import { fakeTart, result } from "./tart-test-support.js"
import {
  IMAGE_PREFIX,
  makeTartProvider,
  vmName,
  type TartImageRecipe,
  type TartOptions
} from "./tart.js"

const spec = { name: "box", tags: { owner: "device-a", machine: "m1" } }
const baseImage = "ghcr.io/cirruslabs/macos-tahoe-base:latest"
const options: TartOptions = { baseImage, cpu: 4, memoryGiB: 8, minFreeDiskGiB: 40 }
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

const imageNameOf = async (tart: ReturnType<typeof fakeTart>): Promise<string> => {
  const provider = makeTartProvider(tart.host, images())
  const prepared = await provider.prepare?.(options, withImage, recorder().progress)
  return prepared?.image ?? ""
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

  it("builds the image once: base clone, app share, setup, stop, rename, then clones VMs from it", async () => {
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
    const image = prepared?.image ?? ""
    const created = await provider.create(spec, prepared ?? options)

    const building = `${image}-building`
    expect(image).toMatch(new RegExp(`^${IMAGE_PREFIX}[0-9a-f]{16}$`))
    expect(events[0]).toBe("stage image")
    expect(events).toContain("stdout ==> Installing Codevisor (dev).app\n")
    expect(events).toContain(`Deleting the older image ${IMAGE_PREFIX}older`)
    expect(tart.commands).toContain(`clone ${baseImage} ${building}`)
    expect(tart.commands).toContain(`start run --no-graphics ${building}`)
    expect(tart.commands).toContain(
      `copyIn ${building} /Builds/Debug/Codevisor (dev).app /Applications`
    )
    expect(tart.commands).toContain(`stop ${building}`)
    expect(tart.commands).toContain(`rename ${building} ${image}`)
    expect(scripts[0]).toContain("app='/Applications/Codevisor (dev).app'")
    expect(created).toEqual({
      providerMachineId: vmName(spec),
      platform: "darwin",
      preinstalled: true
    })
    expect(tart.commands).toContain(`clone ${image} ${vmName(spec)}`)
    expect(tart.vms.map((vm) => vm.Name)).toEqual([image, vmName(spec)])
  })

  it("lets a second machine wait for the image another one is preparing", async () => {
    const tart = fakeTart({ onScript: () => result("") })
    const provider = makeTartProvider(tart.host, images())
    const second = recorder()

    const [first, next] = await Promise.all([
      provider.prepare?.(options, withImage, recorder().progress),
      provider.prepare?.(options, withImage, second.progress)
    ])

    expect(next?.image).toBe(first?.image)
    expect(
      tart.commands.filter((command) => command.startsWith(`clone ${baseImage}`))
    ).toHaveLength(1)
    expect(second.events).toEqual([
      "stage image",
      "Waiting for the macOS image another machine is preparing"
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
      onScript: () => ({
        exitCode: 1,
        stdout: "==> Installing the Codevisor server\n",
        stderr: "curl: (7) refused\n"
      })
    })
    const provider = makeTartProvider(tart.host, images(releaseRecipe))

    await expect(provider.prepare?.(options, withImage, recorder().progress)).rejects.toThrow(
      "Preparing the macOS image failed (exit 1):\n==> Installing the Codevisor server\ncurl: (7) refused"
    )
    expect(tart.vms).toEqual([])
  })

  it("stops and deletes the half-built VM when the app can't be copied in", async () => {
    const tart = fakeTart({ copyExit: 2 })
    const provider = makeTartProvider(tart.host, images())

    await expect(provider.prepare?.(options, withImage, recorder().progress)).rejects.toThrow(
      "Copying Codevisor into the macOS image failed (exit 2):\ntar: broken pipe"
    )
    expect(tart.vms).toEqual([])
  })

  it("keeps cloning the base image when there is no app to install, or when the project names an image", async () => {
    const tart = fakeTart({})
    const bare = makeTartProvider(tart.host, { recipe: () => Promise.resolve(undefined) })
    const pinned = { ...options, image: "my-image" }
    const prepared = makeTartProvider(tart.host, images())
    const preparedName = `${IMAGE_PREFIX}0123456789abcdef`

    expect(await bare.plan?.(options)).toEqual({ stages: ["create", "boot"], preinstalled: false })
    expect((await bare.prepare?.(options, withImage, recorder().progress))?.image).toBe(baseImage)
    expect(await prepared.plan?.(pinned)).toEqual({
      stages: ["create", "boot"],
      preinstalled: false
    })
    expect(await prepared.prepare?.(pinned, withImage, recorder().progress)).toEqual(pinned)
    expect((await prepared.plan?.({ ...options, image: preparedName }))?.preinstalled).toBe(true)
    expect(await makeTartProvider(tart.host).plan?.(options)).toEqual({
      stages: ["create", "boot"],
      preinstalled: false
    })
    expect((await makeTartProvider(tart.host).create(spec, options)).preinstalled).toBe(false)
    expect(tart.commands).toContain(`clone ${baseImage} ${vmName(spec)}`)
  })
})
