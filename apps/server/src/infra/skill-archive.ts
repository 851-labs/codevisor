import { spawn } from "node:child_process"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { gunzipSync } from "node:zlib"

import { treeHash } from "@codevisor/sync"

const MANAGED_MARKER = ".codevisor-managed-skill"

export interface UnpackedSkill {
  readonly path: string
  readonly hash: string
}

const tarExec = (args: ReadonlyArray<string>, input?: Buffer): Promise<Buffer> =>
  new Promise((resolve, reject) => {
    const child = spawn("tar", args, { env: { ...process.env, COPYFILE_DISABLE: "1" } })
    const chunks: Array<Buffer> = []
    child.stdout.on("data", (chunk: Buffer) => chunks.push(chunk))
    child.once("error", reject)
    child.once("close", (code) => {
      if (code === 0) resolve(Buffer.concat(chunks))
      else reject(new Error(`tar exited with ${code}`))
    })
    child.stdin.on("error", () => undefined)
    if (input !== undefined) child.stdin.write(input)
    child.stdin.end()
  })

/* v8 ignore next */
const MAC_METADATA_FLAGS = process.platform === "darwin" ? ["--no-mac-metadata"] : []

export const packSkillArchive = (skillPath: string): Promise<Buffer> =>
  tarExec(["-czf", "-", ...MAC_METADATA_FLAGS, "-C", skillPath, "."])

const EXCLUDED: ReadonlySet<string> = new Set([MANAGED_MARKER])

export const unpackSkillArchive = async (bytes: Buffer): Promise<UnpackedSkill> => {
  const path = await mkdtemp(join(tmpdir(), "codevisor-skill-"))
  try {
    await tarExec(["-xzf", "-", "-C", path], bytes)
    return { path, hash: await treeHash(path, { exclude: EXCLUDED }) }
  } catch (error) {
    await rm(path, { recursive: true, force: true })
    throw error
  }
}

export const skillTreeHash = (path: string): Promise<string> =>
  treeHash(path, { exclude: EXCLUDED })

export const archiveEntryNames = (bytes: Buffer): ReadonlyArray<string> => {
  const tar = gunzipSync(bytes)
  const names: Array<string> = []
  let offset = 0
  while (offset + 512 <= tar.length) {
    const header = tar.subarray(offset, offset + 512)
    if (header.every((byte) => byte === 0)) break
    names.push(
      header
        .subarray(0, 100)
        .toString("utf8")
        .replace(/\0[^]*$/, "")
    )
    const size = Number.parseInt(
      header.subarray(124, 136).toString("ascii").replaceAll("\0", "").trim() || "0",
      8
    )
    offset += 512 + Math.ceil(size / 512) * 512
  }
  return names
}

const isMacMetadataJunk = (name: string): boolean => {
  const base = name.split("/").findLast(Boolean) ?? ""
  return base.startsWith("._") || base === ".DS_Store"
}

export const verifySkillArchive = async (id: string, bytes: Buffer): Promise<boolean> => {
  try {
    if (archiveEntryNames(bytes).some(isMacMetadataJunk)) return false
    const unpacked = await unpackSkillArchive(bytes)
    const matches = unpacked.hash === id
    await rm(unpacked.path, { recursive: true, force: true })
    return matches
  } catch {
    return false
  }
}
