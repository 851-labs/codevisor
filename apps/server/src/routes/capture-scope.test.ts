import { mkdirSync, mkdtempSync, rmSync, truncateSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { MAX_UPLOAD_BYTES } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { tempDirs } from "../test-support.js"
import { capturablePath } from "./capture-scope.js"

const folder = (): string => {
  const created = mkdtempSync(join(tmpdir(), "codevisor-capture-scope-"))
  tempDirs.push(created)
  return created
}

describe("capture scope", () => {
  it("refuses folders and files over the upload limit", async () => {
    const cwd = folder()
    mkdirSync(join(cwd, "shots"))
    writeFileSync(join(cwd, "huge.bin"), "")
    truncateSync(join(cwd, "huge.bin"), MAX_UPLOAD_BYTES + 1)

    expect(await capturablePath(join(cwd, "shots"), cwd)).toBeUndefined()
    expect(await capturablePath(join(cwd, "huge.bin"), cwd)).toBeUndefined()
  })

  it("still captures temp files for a chat whose folder is gone", async () => {
    const cwd = folder()
    const scratch = folder()
    writeFileSync(join(scratch, "shot.png"), "pixels")
    rmSync(cwd, { recursive: true })

    expect(await capturablePath(join(scratch, "shot.png"), cwd)).toMatch(/shot\.png$/)
  })
})
