import { describe, expect, it } from "vitest"

import { CONTAINER_IMAGE_REPOSITORY, type ContainerImages } from "./apple-container-image.js"
import { fakeContainerHost, ok, type FakeContainer } from "./apple-container-test-support.js"
import {
  appleContainerAdapter,
  containerName,
  DEFAULT_CONTAINER_IMAGE,
  makeAppleContainerProvider
} from "./apple-container.js"
import type { ProvisionPlan } from "./provider.js"
import { silentProgress } from "./tart-vm.js"

const machine = "0b5c6d1e-1111-4222-8333-944455556666"
const spec = { name: "box", tags: { owner: "device-a", machine } }
const name = `codevisor-${machine}`
const prepared = `${CONTAINER_IMAGE_REPOSITORY}:0123456789abcdef`
const recipe: ContainerImages = { recipe: () => Promise.resolve({ fingerprint: "stable 0.1.109" }) }
const noRecipe: ContainerImages = { recipe: () => Promise.resolve(undefined) }
const profile = { image: DEFAULT_CONTAINER_IMAGE, cpu: 2, memoryGiB: 4 }
const gib = 1024 ** 3

const running = (id: string, memoryGiB: number, labels = {}): FakeContainer => ({
  id,
  state: "running",
  labels,
  memoryGiB
})

const recorder = () => {
  const stages: string[] = []
  const logs: string[] = []
  const progress = {
    stage: (stage: string) => stages.push(stage),
    log: (line: string) => logs.push(line),
    output: () => undefined
  }
  return { stages, logs, progress }
}

const unavailable = (setup: Parameters<typeof fakeContainerHost>[0]) =>
  makeAppleContainerProvider(fakeContainerHost(setup).host).availability?.(profile)

const planWith = (stages: ProvisionPlan["stages"]): ProvisionPlan => ({
  stages,
  preinstalled: true
})

describe("Apple container provider", () => {
  it("starts a long-lived container from the prepared image and waits until it answers", async () => {
    const fake = fakeContainerHost({ images: [prepared], execFailures: 2 })
    const { stages, progress } = recorder()

    const created = await makeAppleContainerProvider(fake.host).create(
      spec,
      { ...profile, preparedImage: prepared },
      progress
    )

    expect(created).toEqual({ providerMachineId: name, platform: "linux", preinstalled: true })
    expect(stages).toEqual(["boot"])
    expect(
      fake.commands.filter(
        (command) => !command.startsWith("system") && command !== "list --all --format json"
      )
    ).toEqual([
      `run --detach --init --platform linux/arm64 --name ${name} --label codevisor-owner=device-a --label codevisor-machine=${machine} --cpus 2 --memory 4g ${prepared} sleep infinity`,
      `exec ${name} true`,
      `exec ${name} true`,
      `exec ${name} true`
    ])
    expect(fake.sleeps).toEqual([1000, 1000])
  })

  it("falls back to the base image, pulled for arm64 only, with curl and git for install.sh", async () => {
    const fake = fakeContainerHost()

    const created = await makeAppleContainerProvider(fake.host).create(spec, profile)
    const cached = fakeContainerHost({ images: [DEFAULT_CONTAINER_IMAGE] })
    await makeAppleContainerProvider(cached.host).create(spec, profile)

    expect(cached.commands.some((command) => command.startsWith("image pull"))).toBe(false)
    expect(created.preinstalled).toBe(false)
    expect(fake.images).toEqual([DEFAULT_CONTAINER_IMAGE])
    expect(fake.commands).toContain(`image pull --platform linux/arm64 ${DEFAULT_CONTAINER_IMAGE}`)
    expect(fake.commands.at(-1)).toMatch(new RegExp(`^exec ${name} sh -c if command -v apt-get`))
  })

  it("deletes the container when it never answers or can't get curl and git", async () => {
    const silent = fakeContainerHost({ execFailures: 1000 })
    const broken = fakeContainerHost({
      onScript: () => ({ exitCode: 100, stdout: "", stderr: "" })
    })

    await expect(makeAppleContainerProvider(silent.host).create(spec, profile)).rejects.toThrow(
      `The container ${name} never answered`
    )
    await expect(makeAppleContainerProvider(broken.host).create(spec, profile)).rejects.toThrow(
      "Installing curl and git failed (exit 100)"
    )
    expect(silent.sleeps).toHaveLength(30)
    expect(silent.containers).toEqual([])
    expect(broken.containers).toEqual([])
  })

  it("counts every running container's memory against the Mac before starting one", async () => {
    const fake = fakeContainerHost({ containers: [running("a", 16), running("b", 12)] })
    const provider = makeAppleContainerProvider(fake.host)

    expect(await provider.capacity?.({ ...profile, memoryGiB: 4 })).toBeUndefined()
    expect(await provider.capacity?.({ ...profile, memoryGiB: 6 })).toBe(
      "This Mac doesn't have enough free memory right now"
    )
    await expect(provider.create(spec, { ...profile, memoryGiB: 6 })).rejects.toThrow(
      "This Mac doesn't have enough free memory right now: running containers already reserve 28 of the 32 GB it can spare, and this profile needs 6 GB"
    )
    expect(fake.containers.map((container) => container.id)).toEqual(["a", "b"])
  })

  it("has room when container isn't installed or its services are stopped", async () => {
    const busy = [running("a", 40)]

    expect(
      await makeAppleContainerProvider(
        fakeContainerHost({ installed: false, containers: busy }).host
      ).capacity?.(profile)
    ).toBeUndefined()
    expect(
      await makeAppleContainerProvider(
        fakeContainerHost({ systemRunning: false, containers: busy }).host
      ).capacity?.(profile)
    ).toBeUndefined()
  })

  it("explains why a Mac can't run containers at all", async () => {
    expect(await unavailable({})).toBeUndefined()
    expect(await unavailable({ installed: false })).toBeUndefined()
    expect(await unavailable({ macOS: "15.6.1" })).toBe(
      "Apple containers need macOS 26 or later, and this Mac runs macOS 15.6.1"
    )
    expect(
      await unavailable({ cli: { binary: "/opt/homebrew/bin/container", version: "0.9.0" } })
    ).toBe(
      "This Mac has container 0.9.0 at /opt/homebrew/bin/container, and Codevisor needs 1.3 or a later 1.x release. Update it from github.com/apple/container"
    )
    expect(
      await unavailable({ cli: { binary: "/usr/local/bin/container", version: "2.0.0" } })
    ).toMatch(/^This Mac has container 2\.0\.0/)
    expect(await unavailable({ freeGiB: 9.5 })).toBe(
      "Only 9.5 GB of disk is free on this Mac; a container sandbox needs 10 GB"
    )
  })

  it("plans installing container and building the image only when they're missing", async () => {
    const plan = (
      setup: Parameters<typeof fakeContainerHost>[0],
      images = recipe,
      values: Record<string, string | number> = profile
    ) => appleContainerAdapter(fakeContainerHost(setup).host, images).connect({}).plan?.(values)
    const built = [await builtName()]

    expect(await plan({ installed: false })).toEqual(
      planWith(["container", "image", "create", "boot"])
    )
    expect(await plan({ systemRunning: false })).toEqual(planWith(["image", "create", "boot"]))
    expect(await plan({ images: built })).toEqual(planWith(["create", "boot"]))
    expect(await plan({}, noRecipe)).toEqual({ stages: ["create", "boot"], preinstalled: false })
    expect(await plan({}, noRecipe, { ...profile, preparedImage: prepared })).toEqual(
      planWith(["create", "boot"])
    )
  })

  it("installs container, starts its services and builds the image before the first sandbox", async () => {
    const fake = fakeContainerHost({ installed: false, systemRunning: false })
    const { stages, progress } = recorder()
    const provider = makeAppleContainerProvider(fake.host, recipe)
    const plan = (await provider.plan?.(profile)) ?? planWith([])

    const values = await provider.prepare?.(profile, plan, progress)

    expect(stages).toEqual(["container", "image"])
    expect(fake.commands.slice(0, 3)).toEqual([
      "install",
      "system status --format json",
      "system start --enable-kernel-install"
    ])
    expect(values).toEqual({ ...profile, preparedImage: await builtName() })
  })

  it("installs Codevisor at boot instead when the image won't build or has no recipe", async () => {
    const fake = fakeContainerHost({ failing: "build" })
    const { logs, progress } = recorder()

    const values = await makeAppleContainerProvider(fake.host, recipe).prepare?.(
      profile,
      planWith(["image", "create", "boot"]),
      progress
    )
    const plain = await makeAppleContainerProvider(fakeContainerHost().host, noRecipe).prepare?.(
      profile,
      planWith([]),
      silentProgress
    )

    const unbuildable = fakeContainerHost()
    const offline = { ...unbuildable.host, buildContext: () => Promise.reject("no temp folder") }
    const stale = fakeContainerHost({ installed: false })
    const { stages, progress: staleProgress } = recorder()
    const rescued = await makeAppleContainerProvider(offline, recipe).prepare?.(
      profile,
      planWith([]),
      progress
    )
    await makeAppleContainerProvider(stale.host, noRecipe).prepare?.(
      profile,
      planWith([]),
      staleProgress
    )

    expect(values).toEqual(profile)
    expect(plain).toEqual(profile)
    expect(rescued).toEqual(profile)
    expect(logs).toContain("no temp folder\nInstalling Codevisor when the container starts instead")
    expect(stages).toEqual([])
    expect(stale.commands[0]).toBe("install")
    expect(logs.find((line) => line.includes("build --platform broke"))).toMatch(
      /failed \(exit 1\):\nbuild --platform broke\nInstalling Codevisor when the container starts instead$/
    )
  })

  it("runs scripts with stdin and reads, resumes, lists and deletes its containers", async () => {
    const mine = running(name, 4, { "codevisor-owner": "device-a", "codevisor-machine": machine })
    const fake = fakeContainerHost({
      systemRunning: false,
      containers: [
        mine,
        running("theirs", 4, { "codevisor-owner": "device-b", "codevisor-machine": "x" }),
        running("dev", 4)
      ],
      onScript: (script, options) => ok(`${script}:${options?.stdin ?? ""}`)
    })
    const provider = makeAppleContainerProvider(fake.host)

    const exec = await provider.exec(name, { script: "echo hi", stdin: "code\n" })
    const streamed: string[] = []
    const quiet = await provider.exec(name, {
      script: "true",
      onOutput: (_, text) => streamed.push(text)
    })
    const listed = await provider.list("device-a")
    mine.state = "stopped"
    const stopped = await provider.status(name)
    await provider.resume?.(name)
    const resumed = await provider.status(name)
    await provider.destroy(name)

    expect(exec.stdout).toBe("echo hi:code\n")
    expect(quiet.stdout).toBe("true:")
    expect(fake.commands[0]).toBe(`exec --interactive ${name} sh -c echo hi`)
    expect(fake.commands).toContain("system start --enable-kernel-install")
    expect(listed).toEqual([{ providerMachineId: name, tags: spec.tags }])
    expect([stopped, resumed, await provider.status(name)]).toEqual([
      { state: "stopped" },
      { state: "running" },
      { state: "gone" }
    ])
  })

  it("treats a Mac without container as having no containers", async () => {
    const fake = fakeContainerHost({ installed: false })
    const provider = makeAppleContainerProvider(fake.host)

    await provider.destroy(name)

    expect(await provider.status(name)).toEqual({ state: "gone" })
    expect(await provider.list("device-a")).toEqual([])
    expect(fake.commands).toEqual([])
  })

  it("reports a failed container command with its stderr", async () => {
    const fake = fakeContainerHost({ failing: "run", images: [prepared] })

    await expect(
      makeAppleContainerProvider(fake.host).create(spec, { ...profile, preparedImage: prepared })
    ).rejects.toThrow(/^container run --detach .* failed \(exit 1\): run --detach broke$/)
  })

  it("caps profile sizes to the Mac and keeps names within container's limit", () => {
    const adapter = appleContainerAdapter(
      fakeContainerHost({ hardware: { cpus: 14, memoryBytes: 36 * gib } }).host
    )
    const tiny = appleContainerAdapter(
      fakeContainerHost({ hardware: { cpus: 2, memoryBytes: 4 * gib } }).host
    )

    expect(adapter.hostMaximums?.()).toEqual({ cpu: 12, memoryGiB: 32 })
    expect(tiny.hostMaximums?.()).toEqual({ cpu: 1, memoryGiB: 2 })
    expect(
      containerName({ name: "x", tags: { owner: "o", machine: "m".repeat(80) } })
    ).toHaveLength(63)
  })
})

const builtName = async (): Promise<string> => {
  const fake = fakeContainerHost()
  const values = await makeAppleContainerProvider(fake.host, recipe).prepare?.(
    profile,
    planWith([]),
    silentProgress
  )
  return String(values?.["preparedImage"])
}
