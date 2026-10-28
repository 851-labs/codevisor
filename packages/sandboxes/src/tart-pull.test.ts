import { describe, expect, it } from "vitest"

import type { ProvisionProgress } from "./provider.js"
import { ensurePulled } from "./tart-pull.js"
import { fakeTart } from "./tart-test-support.js"
import { tartCommands } from "./tart-vm.js"

const ubuntu = "ghcr.io/cirruslabs/ubuntu:latest"
const sizing = { cpu: 2, memoryGiB: 4, minFreeDiskGiB: 40 }
const gib = 1024 ** 3
const escape = String.fromCharCode(27)

const tartProgress = (
  before: ReadonlyArray<string>,
  percents: ReadonlyArray<number>,
  after: ReadonlyArray<string>
): string =>
  [
    ...before.map((line) => `${line}\n`),
    ...percents.map((percent) => `${escape}[1A\r${escape}[J${percent}%\n`),
    ...after.map((line) => `${line}\n`)
  ].join("")

const recorder = () => {
  const events: string[] = []
  const progress: ProvisionProgress = {
    stage: (stage) => events.push(`stage ${stage}`),
    log: (line) => events.push(line),
    output: (stream, text) => events.push(`${stream} ${text}`)
  }
  return { events, progress }
}

const pullFrom = async (tart: ReturnType<typeof fakeTart>, image = ubuntu) => {
  const { events, progress } = recorder()
  await ensurePulled(tart.host, tartCommands(tart.host), image, sizing, progress)
  return events
}

describe("Pulling a Tart image", () => {
  it("pulls an image that isn't cached and logs its download every 5%", async () => {
    const tart = fakeTart({
      pulled: [],
      imageBytes: 10 * gib,
      pullOutput: tartProgress(
        ["pulling disk (3.0 GB compressed)...", "0%"],
        [1, 4, 5, 9, 10, 100],
        ["pulling NVRAM..."]
      )
    })

    const events = await pullFrom(tart)

    expect(events).toEqual([
      `tart pull ${ubuntu}`,
      "pulling disk (3.0 GB compressed)...",
      "Downloaded 0.0 of 3.0 GB (0%)",
      "Downloaded 0.1 of 3.0 GB (5%)",
      "Downloaded 0.3 of 3.0 GB (10%)",
      "Downloaded 3.0 of 3.0 GB (100%)",
      "pulling NVRAM..."
    ])
    expect(tart.commands).toContain(`pull ${ubuntu}`)
  })

  it("skips the download when the image is cached or is a local VM", async () => {
    const tart = fakeTart({ pulled: [ubuntu] })

    const cached = await pullFrom(tart)
    const local = await pullFrom(tart, "codevisor-image-0123456789abcdef")

    expect([...cached, ...local]).toEqual([])
    expect(tart.commands).toEqual(["list --source oci --format json"])
  })

  it("refuses to download an image that won't fit, saying how much space it needs", async () => {
    const tart = fakeTart({ pulled: [], pullOutput: "", imageBytes: 35 * gib, freeGiB: 52 })

    await expect(pullFrom(tart)).rejects.toThrow(
      "Only 52.0 GB of disk is free on this Mac; downloading this image and running it needs 75 GB"
    )
    expect(tart.commands).not.toContain(`pull ${ubuntu}`)
  })

  it("reports a failed pull, and percent alone when Tart never said the size", async () => {
    const failing = fakeTart({ pulled: [], failing: "pull" })
    const sizeless = fakeTart({ pulled: [], pullOutput: `${escape}[1A\r${escape}[J37%` })

    await expect(pullFrom(failing)).rejects.toThrow(
      `tart pull ${ubuntu} failed (exit 1): pull broke`
    )
    expect(await pullFrom(sizeless)).toEqual([`tart pull ${ubuntu}`, "Downloaded 37%"])
  })
})
