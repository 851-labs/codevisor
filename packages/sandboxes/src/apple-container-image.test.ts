import { describe, expect, it } from "vitest"

import { containerCommands } from "./apple-container-host.js"
import {
  CONTAINER_IMAGE_REPOSITORY,
  ensureContainerImage,
  isPreparedContainerImage,
  preparedContainerImage
} from "./apple-container-image.js"
import { fakeContainerHost } from "./apple-container-test-support.js"
import { silentProgress } from "./tart-vm.js"

const base = "docker.io/library/debian:bookworm-slim"
const stable = preparedContainerImage(base, { fingerprint: "stable 0.1.109" })
const older = `${CONTAINER_IMAGE_REPOSITORY}:00000000aaaaaaaa`

const build = (fake: ReturnType<typeof fakeContainerHost>, image = stable) =>
  ensureContainerImage(fake.host, containerCommands(fake.host), image, silentProgress)

describe("Apple container image", () => {
  it("builds the server into the base image once, then drops the builder, older images and the pulled base", async () => {
    const fake = fakeContainerHost({ images: [older, "node:22-bookworm"] })

    await Promise.all([build(fake), build(fake)])

    expect(fake.contexts).toHaveLength(1)
    expect(fake.contexts[0]).toMatch(
      /^FROM --platform=linux\/arm64 docker\.io\/library\/debian:bookworm-slim\n/
    )
    expect(fake.contexts[0]).toContain(
      "RUN CODEVISOR_NO_SETUP=1 CODEVISOR_NO_SERVICE=1 CODEVISOR_INSTALL_SERVER=1 sh -c 'installer=$(mktemp) && curl -fsSL '\\''https://www.codevisor.dev/install.sh'\\'' -o"
    )
    expect(
      fake.commands.filter(
        (command) => !command.startsWith("image list") && !command.startsWith("list")
      )
    ).toEqual([
      `build --platform linux/arm64 --progress plain --no-cache -t ${stable.name} -f /tmp/build/Containerfile /tmp/build`,
      "dispose context",
      "builder delete --force",
      `image delete ${older}`,
      `image delete ${base}`
    ])
    expect(fake.images).toEqual(["node:22-bookworm", stable.name])
  })

  it("installs this build's server in dev and changes its tag when the server changes", () => {
    const dev = preparedContainerImage(base, {
      fingerprint: "dev archive",
      installUrl: "http://192.168.1.5:4000/install.sh",
      installEnvironment: { CODEVISOR_VERSION: "dev" }
    })

    expect(dev.containerfile).toContain("CODEVISOR_VERSION='dev' sh -c")
    expect(dev.containerfile).toContain("http://192.168.1.5:4000/install.sh")
    expect(preparedContainerImage(base, { fingerprint: "stable 0.1.110" }).name).not.toBe(
      stable.name
    )
    expect(isPreparedContainerImage(`docker.io/library/${stable.name}`)).toBe(true)
    expect(isPreparedContainerImage(base)).toBe(false)
  })

  it("keeps a built image, a running builder and a base image that was already there", async () => {
    const built = fakeContainerHost({ images: [stable.name] })
    const busy = fakeContainerHost({
      images: ["debian:bookworm-slim"],
      containers: [{ id: "buildkit", state: "running", labels: {}, memoryGiB: 2 }]
    })

    await build(built)
    await build(busy)

    expect(built.contexts).toEqual([])
    expect(
      busy.commands.filter(
        (command) => command.startsWith("builder") || command.startsWith("image delete")
      )
    ).toEqual([])
  })

  it("reports the end of the build output and still cleans up when the build fails", async () => {
    const fake = fakeContainerHost({ failing: "build" })

    await expect(build(fake)).rejects.toThrow(
      "Building the Codevisor container image failed (exit 1):\nbuild --platform broke"
    )
    expect(fake.commands.slice(-2)).toEqual(["dispose context", "builder delete --force"])
  })

  it("tolerates a builder or an older image that won't delete", async () => {
    const stuckBuilder = fakeContainerHost({ failing: "builder delete" })
    const stuckImage = fakeContainerHost({ failing: "image delete", images: [older] })

    await build(stuckBuilder)
    await build(stuckImage)

    expect(stuckBuilder.images).toEqual([stable.name])
    expect(stuckImage.images).toEqual([older, stable.name])
  })
})
