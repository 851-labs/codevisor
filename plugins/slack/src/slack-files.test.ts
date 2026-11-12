import { mkdtemp, readFile, rm, truncate, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { expect, it, onTestFinished } from "vitest"

import { localSlackFiles, maxUploadBytes } from "./slack-files.js"

const temporaryFolder = async () => {
  const folder = await mkdtemp(join(tmpdir(), "slack-files-"))
  onTestFinished(() => rm(folder, { recursive: true, force: true }))
  return folder
}

it("saves downloads under the file's id with a safe name", async () => {
  const folder = await temporaryFolder()

  const path = await localSlackFiles(folder).save(
    "F1",
    "../q3 report?.csv",
    new TextEncoder().encode("a,b")
  )

  expect(path).toBe(join(folder, "F1", "q3 report_.csv"))
  expect(await readFile(path, "utf8")).toBe("a,b")
})

it("reads a local file to upload and refuses one over the upload limit", async () => {
  const folder = await temporaryFolder()
  const small = join(folder, "notes.txt")
  const huge = join(folder, "huge.bin")
  await writeFile(small, "hi")
  await writeFile(huge, "")
  await truncate(huge, maxUploadBytes + 1)

  const read = await localSlackFiles(folder).read(small)

  expect([read.name, new TextDecoder().decode(read.bytes)]).toEqual(["notes.txt", "hi"])
  await expect(localSlackFiles(folder).read(huge)).rejects.toThrow(
    "over Slack's 100 MB upload limit"
  )
})
