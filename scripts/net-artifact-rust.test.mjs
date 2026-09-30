import assert from "node:assert/strict"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"

import { findRustup, rustupProxyDirectories } from "./net-artifact.mjs"

const directory = (root, name, files) => {
  const path = join(root, name)
  mkdirSync(path, { recursive: true })
  for (const file of files) writeFileSync(join(path, file), "")
  return path
}

test("rustup is looked for in its installer's and Homebrew's locations, the installer's first", () => {
  assert.deepEqual(rustupProxyDirectories("/Users/me"), [
    "/Users/me/.cargo/bin",
    "/opt/homebrew/opt/rustup/bin",
    "/usr/local/opt/rustup/bin"
  ])
})

test("the first directory with both rustup and its cargo proxy wins; a lone cargo doesn't count", async () => {
  const root = mkdtempSync(join(tmpdir(), "net-rustup-"))
  try {
    // Homebrew's standalone `rust` has cargo but no rustup: never picked.
    const standalone = directory(root, "rust", ["cargo", "rustc"])
    const homebrew = directory(root, "rustup", ["rustup", "cargo", "rustc"])
    const installer = directory(root, "cargo-bin", ["rustup", "cargo"])
    assert.equal(await findRustup([standalone, homebrew]), homebrew)
    assert.equal(await findRustup([installer, homebrew]), installer)
    assert.equal(await findRustup([standalone]), undefined)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})
