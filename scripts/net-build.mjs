#!/usr/bin/env node
import process from "node:process"
import { fileURLToPath } from "node:url"

import { buildNodeAddon, buildSwiftFramework } from "../packages/devtools/src/net-build.ts"

const repoRoot = fileURLToPath(new URL("..", import.meta.url))
const [kind, target] = process.argv.slice(2)

try {
  if (kind === "swift") await buildSwiftFramework(repoRoot)
  else if (kind === "node" && target !== undefined) await buildNodeAddon(repoRoot, target)
  else throw new Error("usage: net-build.mjs <swift | node <target>>")
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
}
