import { execFile } from "node:child_process"
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { describe, expect, it, onTestFinished } from "vitest"

import { packageFamilies } from "./package-managers.js"

const run = promisify(execFile)

const zypperScreenInstall = packageFamilies.find((family) => family.manager === "zypper")
  ?.screenCommands[0]

const machineWhereZypperExits = (code: number, installs: ReadonlyArray<string>): string => {
  const bin = mkdtempSync(join(tmpdir(), "cv-zypper-"))
  onTestFinished(() => rmSync(bin, { recursive: true, force: true }))
  const installed = installs.map(
    (program) => `printf '#!/bin/sh\\n' > "${bin}/${program}"; chmod +x "${bin}/${program}"`
  )
  writeFileSync(join(bin, "zypper"), `#!/bin/sh\n${installed.join("\n")}\nexit ${code}\n`)
  writeFileSync(
    join(bin, "env"),
    '#!/bin/sh\nwhile [ "${1#*=}" != "$1" ]; do shift; done\nexec "$@"\n'
  )
  chmodSync(join(bin, "zypper"), 0o755)
  chmodSync(join(bin, "env"), 0o755)
  return bin
}

const exitOf = async (bin: string): Promise<number> => {
  const [program, ...args] = zypperScreenInstall ?? []
  try {
    await run(program!, args, { env: { PATH: `${bin}:/usr/bin:/bin` } })
    return 0
  } catch (cause) {
    const code = typeof cause === "object" && cause !== null && "code" in cause ? cause.code : -1
    return typeof code === "number" ? code : -1
  }
}

describe("installing what sharing the screen needs with zypper", () => {
  it.each([
    ["installed, with a warning", 107, ["x0vncserver", "notify-send"], 0],
    ["skipped a repository but installed both programs", 106, ["x0vncserver", "notify-send"], 0],
    ["skipped a repository and fell short", 106, ["notify-send"], 106],
    ["failed", 4, [], 4]
  ])(
    "passes when zypper %s only if both programs are there",
    async (_name, code, installs, exit) => {
      expect(await exitOf(machineWhereZypperExits(code, installs))).toBe(exit)
    }
  )
})
