#!/usr/bin/env node
import { createHash } from "node:crypto"
import { readdirSync, readFileSync, writeFileSync } from "node:fs"
import { basename, join } from "node:path"

const tapDir = process.argv[2]
const version = process.env.VERSION
const repository = process.env.REPOSITORY ?? "851-labs/HerdMan-v2"
const artifactDir = process.env.ARTIFACT_DIR ?? "dist/release"

if (tapDir === undefined || tapDir.length === 0) {
  throw new Error("usage: update-homebrew-tap.mjs <tap-dir>")
}
if (version === undefined || version.length === 0) {
  throw new Error("VERSION is required")
}

const files = readdirSync(artifactDir)
const appZip = files.find((file) => file === "HerdMan-macOS.zip")
const serverArchives = files.filter((file) => /^herdman-server-.+\.tar\.gz$/.test(file)).sort()

if (appZip === undefined) {
  throw new Error(`HerdMan-macOS.zip not found in ${artifactDir}`)
}
if (serverArchives.length === 0) {
  throw new Error(`No herdman-server archives found in ${artifactDir}`)
}

const sha256 = (file) =>
  createHash("sha256")
    .update(readFileSync(join(artifactDir, file)))
    .digest("hex")
const releaseUrl = (file) =>
  `https://github.com/${repository}/releases/download/v#{version}/${file}`

writeFileSync(
  join(tapDir, "Casks", "herdman.rb"),
  `cask "herdman" do
  version "${version}"
  sha256 "${sha256(appZip)}"

  url "${releaseUrl(appZip)}"
  name "HerdMan"
  desc "ACP chat client and local HerdMan server"
  homepage "https://github.com/${repository}"

  depends_on formula: "node"

  app "HerdMan.app"
end
`
)

const targetAssets = Object.fromEntries(
  serverArchives.map((file) => [
    file.replace(/^herdman-server-/, "").replace(/\.tar\.gz$/, ""),
    file
  ])
)

const targetBlock = (target) => {
  const file = targetAssets[target]
  if (file === undefined) {
    return undefined
  }
  return `    url "${releaseUrl(file)}"
    sha256 "${sha256(file)}"`
}

const conditions = [
  ["OS.mac? && Hardware::CPU.arm?", "darwin-arm64"],
  ["OS.mac? && Hardware::CPU.intel?", "darwin-x64"],
  ["OS.linux? && Hardware::CPU.arm?", "linux-arm64"],
  ["OS.linux? && Hardware::CPU.intel?", "linux-x64"]
].flatMap(([condition, target]) => {
  const block = targetBlock(target)
  return block === undefined ? [] : [{ condition, block }]
})

if (conditions.length === 0) {
  throw new Error("No supported Homebrew server targets were produced")
}

const urlBlock = conditions
  .map(({ condition, block }, index) => {
    const keyword = index === 0 ? "if" : "elsif"
    return `  ${keyword} ${condition}
${block}`
  })
  .join("\n")

const supportedTargets = Object.keys(targetAssets).join(", ")

writeFileSync(
  join(tapDir, "Formula", "herdman-server.rb"),
  `class HerdmanServer < Formula
  desc "Local and remote HerdMan ACP server"
  homepage "https://github.com/${repository}"
  version "${version}"

${urlBlock}
  else
    odie "No HerdMan server archive is available for this platform. Supported targets: ${supportedTargets}"
  end

  depends_on "node"

  def install
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bin/herdman-server"
    bin.install_symlink libexec/"bin/herdman-terminal-proxy"
  end

  test do
    assert_match "Missing --server", shell_output("#{bin}/herdman-terminal-proxy 2>&1", 1)
  end
end
`
)

console.log(`Updated ${basename(tapDir)} for HerdMan ${version}`)
