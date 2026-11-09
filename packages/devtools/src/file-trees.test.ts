import assert from "node:assert/strict"
import { chmod, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { onTestFinished, test } from "vitest"

import { sameVolume } from "./apfs-clone.ts"
import { describeDifference, listTree } from "./file-trees.ts"

async function tree(files: Record<string, string> = { "bin/tool": "binary" }) {
  const root = await mkdtemp(join(tmpdir(), "codevisor-file-trees-"))
  onTestFinished(() => rm(root, { recursive: true, force: true }))
  for (const [path, contents] of Object.entries(files)) {
    await mkdir(join(root, path, ".."), { recursive: true })
    await writeFile(join(root, path), contents)
  }
  await symlink("bin/tool", join(root, "tool"))
  return root
}

test("trees list directories, files, and symlinks by relative path", async () => {
  const root = await tree()
  await chmod(join(root, "bin/tool"), 0o755)

  const entries = await listTree(root)

  assert.deepEqual([...entries.keys()].toSorted(), ["bin", "bin/tool", "tool"])
  assert.deepEqual(entries.get("bin"), { type: "directory" })
  assert.deepEqual(entries.get("tool"), { type: "symlink", target: "bin/tool" })
  assert.equal(entries.get("bin/tool")?.type, "file")
  assert.ok(await sameVolume(root, join(root, "bin")))
})

test("tree differences name the first changed, missing, or extra entry", async () => {
  const reference = await listTree(await tree())

  assert.equal(describeDifference(await listTree(await tree()), reference), undefined)
  assert.equal(
    describeDifference(await listTree(await tree({ "bin/tool": "truncated" })), reference),
    "bin/tool changed"
  )
  assert.equal(
    describeDifference(await listTree(await tree({ "bin/other": "binary" })), reference),
    "bin/other missing from store"
  )
  assert.equal(
    describeDifference(await listTree(await tree({ "bin/tool": "binary", extra: "x" })), reference),
    "4 entries, store has 3"
  )

  const retargeted = await tree()
  await rm(join(retargeted, "tool"))
  await symlink("bin", join(retargeted, "tool"))
  assert.equal(describeDifference(await listTree(retargeted), reference), "tool changed")

  const retyped = await tree()
  await rm(join(retyped, "tool"))
  await mkdir(join(retyped, "tool"))
  assert.equal(describeDifference(await listTree(retyped), reference), "tool changed")
})
