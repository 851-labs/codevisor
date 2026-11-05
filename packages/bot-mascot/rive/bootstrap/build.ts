import { execFileSync } from "node:child_process"
import { mkdirSync, writeFileSync } from "node:fs"

import { mainArtboard } from "./character.js"
import { colorTable, slotCounts } from "./colors.js"
import {
  convertersXml,
  eyewearEnum,
  fixPaintKeys,
  hatEnum,
  modeEnum,
  outfitEnum,
  vmXml
} from "./data.js"
import { faceArtboard } from "./face.js"
import { OUT_DIR } from "./parts.js"

const REPO_ROOT = new URL("../../../../", import.meta.url).pathname

mkdirSync(OUT_DIR + "build", { recursive: true })
writeFileSync(
  OUT_DIR + "rive.yaml",
  "name: mascot\noutput:\n  dir: ../../resources\nlogs:\n  file: build/rive.log\n  problems: build/problems.log\n"
)
const doc = (content: string) => `<Rive version="1" kind="fragment">\n${content}\n</Rive>\n`
writeFileSync(OUT_DIR + "1-character.rml", fixPaintKeys(doc(mainArtboard)))
writeFileSync(OUT_DIR + "2-face.rml", fixPaintKeys(doc(faceArtboard)))
writeFileSync(
  OUT_DIR + "3-data.rml",
  doc([modeEnum.xml, hatEnum.xml, outfitEnum.xml, eyewearEnum.xml, convertersXml, vmXml].join("\n"))
)
const colorsPath = new URL("../../src/data/rive-colors.json", import.meta.url).pathname
writeFileSync(colorsPath, `${JSON.stringify(colorTable, null, 2)}\n`)
execFileSync("bun", ["x", "oxfmt", "-c", REPO_ROOT + ".oxfmtrc.json", colorsPath], {
  cwd: REPO_ROOT
})
console.log(
  "slots:",
  [...slotCounts].map(([c, n]) => `${c}=${n}`).join(" "),
  "| colors.json",
  JSON.stringify(colorTable).length,
  "bytes"
)
