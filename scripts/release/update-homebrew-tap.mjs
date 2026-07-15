#!/usr/bin/env node
import { createHash } from "node:crypto"
import { existsSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { basename, join } from "node:path"

const tapDir = process.argv[2]
const version = process.env.VERSION
const repository = process.env.REPOSITORY ?? process.env.GITHUB_REPOSITORY ?? "851-labs/codevisor"
const artifactDir = process.env.ARTIFACT_DIR ?? "dist/release"
const artifactBaseUrl =
  process.env.ARTIFACT_BASE_URL ?? `https://github.com/${repository}/releases/download/v#{version}`

if (tapDir === undefined || tapDir.length === 0) {
  throw new Error("usage: update-homebrew-tap.mjs <tap-dir>")
}
if (version === undefined || version.length === 0) {
  throw new Error("VERSION is required")
}

const files = readdirSync(artifactDir)
const appZip = files.find((file) => file === "Codevisor-macOS.zip")
const serverArchives = files.filter((file) => /^codevisor-server-.+\.tar\.gz$/.test(file)).sort()

if (appZip === undefined) {
  throw new Error(`Codevisor-macOS.zip not found in ${artifactDir}`)
}
if (serverArchives.length === 0) {
  throw new Error(`No codevisor-server archives found in ${artifactDir}`)
}

const sha256 = (file) =>
  createHash("sha256")
    .update(readFileSync(join(artifactDir, file)))
    .digest("hex")
const releaseUrl = (file) => `${artifactBaseUrl.replace(/\/$/, "")}/${file}`
const updateRenameFile = (filename, oldName, newName) => {
  const path = join(tapDir, filename)
  const renames = existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : {}
  renames[oldName] = newName
  writeFileSync(path, `${JSON.stringify(renames, null, 2)}\n`)
}

writeFileSync(
  join(tapDir, "Casks", "codevisor.rb"),
  `cask "codevisor" do
  version "${version}"
  sha256 "${sha256(appZip)}"

  url "${releaseUrl(appZip)}"
  name "Codevisor"
  desc "ACP chat client and local Codevisor server"
  homepage "https://github.com/${repository}"

  # The app also updates itself in place, so only explicit \`brew upgrade\`
  # (or --greedy) should touch it.
  auto_updates true

  app "Codevisor.app"

  # Quit a running app before the bundle is swapped. The preflight covers
  # upgrades from cask versions that predate the uninstall stanza; the guard
  # keeps AppleScript from launching the app on a fresh install.
  preflight do
    system_command "/usr/bin/osascript",
                   args: [
                     "-e",
                     'if application id "com.851labs.HerdMan" is running then ' \\
                     'tell application id "com.851labs.HerdMan" to quit'
                   ],
                   must_succeed: false
    system_command "/bin/rm",
                   args: ["-rf", "#{appdir}/HerdMan.app"]
  end

  uninstall quit: "com.851labs.HerdMan"

  # Relaunch after install/upgrade so \`brew upgrade\` hands back a running,
  # current app (which in turn restarts an outdated local server on launch).
  postflight do
    system_command "/usr/bin/open",
                   args: ["-a", "#{appdir}/Codevisor.app"],
                   must_succeed: false
  end
end
`
)
updateRenameFile("cask_renames.json", "herdman", "codevisor")
rmSync(join(tapDir, "Casks", "herdman.rb"), { force: true })

const targetAssets = Object.fromEntries(
  serverArchives.map((file) => [
    file.replace(/^codevisor-server-/, "").replace(/\.tar\.gz$/, ""),
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
  join(tapDir, "Formula", "codevisor-server.rb"),
  `class CodevisorServer < Formula
  desc "Local and remote Codevisor ACP server"
  homepage "https://github.com/${repository}"
  version "${version}"

${urlBlock}
  else
    odie "No Codevisor server archive is available for this platform. Supported targets: ${supportedTargets}"
  end

  def install
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bin/codevisor"
    bin.install_symlink libexec/"bin/codevisor-server"
    bin.install_symlink libexec/"bin/codevisor-terminal-proxy"
  end

  test do
    assert_match "codevisor", shell_output("#{bin}/codevisor --version")
    assert_match "Missing --server", shell_output("#{bin}/codevisor-terminal-proxy 2>&1", 1)
  end
end
`
)
updateRenameFile("formula_renames.json", "herdman-server", "codevisor-server")
rmSync(join(tapDir, "Formula", "herdman-server.rb"), { force: true })

console.log(`Updated ${basename(tapDir)} for Codevisor ${version}`)
