import { execFileSync } from "node:child_process"
import { writeFileSync } from "node:fs"

import { colorTable } from "./colors.js"

const REPO_ROOT = new URL("../../../../", import.meta.url).pathname
const colorsPath = new URL("../../src/data/rive-colors.json", import.meta.url).pathname

export function writeColorTable(): void {
  writeFileSync(colorsPath, `${JSON.stringify(colorTable, null, 2)}\n`)
  execFileSync("bun", ["x", "oxfmt", "-c", REPO_ROOT + ".oxfmtrc.json", colorsPath], {
    cwd: REPO_ROOT
  })
}

if (import.meta.main) writeColorTable()
