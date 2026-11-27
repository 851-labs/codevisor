import assert from "node:assert/strict"
import { execFileSync, spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { after } from "node:test"

const installer = readFileSync(new URL("../../apps/www/public/install.sh", import.meta.url), "utf8")
export const stableURL = "https://updates.codevisor.dev/server/stable.json"
const githubLatestURL = "https://api.github.com/repos/851-labs/codevisor/releases/latest"
export const downloadBase = "https://github.com/851-labs/codevisor/releases/download"

const sharedRoot = mkdtempSync(join(tmpdir(), "codevisor-installer-commands-"))
after(() => rmSync(sharedRoot, { recursive: true, force: true }))
const sharedCommands = join(sharedRoot, "commands")
mkdirSync(sharedCommands)
writeFileSync(
  join(sharedRoot, "sha256.mjs"),
  `import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
console.log(createHash('sha256').update(readFileSync(process.argv[2])).digest('hex'));`
)
for (const [command, body] of Object.entries({
  uname:
    'case "$1" in -s) printf "%s\\n" "$TEST_PLATFORM";; -m) printf "%s\\n" "$TEST_ARCH";; *) exit 1;; esac',
  id: 'case "${1:-}" in -un) printf "installer-test\\n";; *) printf "%s\\n" "$TEST_UID";; esac',
  getent: 'grep "^$2:" "$TEST_ROOT/passwd"',
  useradd: [
    "for name; do :; done",
    'printf "useradd %s\\n" "$*" >> "$TEST_SERVICES"',
    'mkdir -p "$TEST_ROOT/home/$name"',
    'printf "%s:x:1002:1002::%s:/bin/sh\\n" "$name" "$TEST_ROOT/home/$name" >> "$TEST_ROOT/passwd"'
  ].join("\n"),
  runuser: 'printf "as %s: %s\\n" "$2" "$*" >> "$TEST_ROOT/runuser.log"\nshift 3\nexec "$@"',
  loginctl: 'printf "loginctl %s\\n" "$*" >> "$TEST_SERVICES"',
  tee: 'printf "tee %s: %s\\n" "$*" "$(cat)" >> "$TEST_SERVICES"',
  systemctl: 'printf "%s\\n" "$*" >> "$TEST_SERVICES"',
  launchctl: 'printf "launchctl %s\\n" "$*" >> "$TEST_SERVICES"',
  osascript: "exit 0",
  sysctl: 'printf "%s\\n" "${TEST_HW_ARM64:-}"',
  hdiutil: "exit 71",
  sha256sum: `exec '${process.execPath.replaceAll("'", "'\\''")}' '${join(sharedRoot, "sha256.mjs")}' "$@"`
})) {
  writeFileSync(join(sharedCommands, command), `#!/bin/sh\nset -eu\n${body}\n`, { mode: 0o755 })
}
writeFileSync(
  join(sharedCommands, "curl"),
  `#!${process.execPath}
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
const args = process.argv.slice(2);
const url = args.at(-1);
appendFileSync(process.env.TEST_REQUESTS, JSON.stringify({ url, args }) + '\\n');
const response = JSON.parse(readFileSync(process.env.TEST_ROOT + '/responses.json'))[url];
if (!response) { console.error('Unexpected URL: ' + url); process.exit(22); }
if (response.status) process.exit(response.status);
const body = response.file ? readFileSync(response.file) : response.body;
const output = args.indexOf('-o');
if (output === -1) process.stdout.write(body);
else writeFileSync(args[output + 1], body);
`,
  { mode: 0o755 }
)

const runShell = (input, args, options) =>
  new Promise((resolve) => {
    const child = spawn("/bin/sh", ["-s", "--", ...args], options)
    let stdout = ""
    let stderr = ""
    child.stdout.setEncoding("utf8").on("data", (chunk) => (stdout += chunk))
    child.stderr.setEncoding("utf8").on("data", (chunk) => (stderr += chunk))
    let spawnError
    child.once("error", (error) => (spawnError = error))
    child.once("close", (status, signal) =>
      resolve(
        spawnError === undefined
          ? { status, signal, stdout, stderr }
          : { error: spawnError, status: null, stdout, stderr }
      )
    )
    child.stdin.end(input)
  })

export const install = async (t, options = {}) => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-installer-"))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const bin = join(root, "commands")
  const runtime = join(root, "runtime")
  const archiveRoot = join(root, "archive")
  for (const directory of [bin, runtime, join(archiveRoot, "bin")]) {
    mkdirSync(directory, { recursive: true })
  }
  writeFileSync(join(runtime, "old-runtime"), "existing installation")
  const version = options.expectedVersion ?? "0.1.99"
  const architecture = options.architecture ?? "x86_64"
  const os = options.platform === "Darwin" ? "darwin" : "linux"
  const target = `${os}-${architecture === "x86_64" ? "x64" : "arm64"}`
  for (const name of ["codevisor", "codevisor-server", "codevisor-terminal-proxy"]) {
    const body =
      name === "codevisor" && options.cli !== undefined
        ? options.cli
        : `printf 'codevisor ${version}\\n'`
    writeFileSync(join(archiveRoot, "bin", name), `#!/bin/sh\n${body}\n`, { mode: 0o755 })
  }
  const archive = join(root, "server.tar.gz")
  execFileSync("tar", ["-czf", archive, "-C", archiveRoot, "."])
  const digest = createHash("sha256").update(readFileSync(archive)).digest("hex")
  const checksum = join(root, "checksum")
  writeFileSync(checksum, `${digest}  codevisor-server-${target}.tar.gz\n`)
  const archiveURL = `${options.archiveBase ?? `${downloadBase}/v${version}`}/codevisor-server-${target}.tar.gz`
  const responses = {
    [stableURL]: {
      body: options.manifest ?? JSON.stringify({ version: "0.1.99", buildNumber: 422 }, null, 2),
      status: options.manifestStatus ?? 0
    },
    [githubLatestURL]: { body: JSON.stringify({ tag_name: "v0.1.94" }) },
    [archiveURL]: { file: archive },
    [`${archiveURL}.sha256`]: { file: checksum },
    [`${downloadBase}/v${version}/Codevisor-arm64.dmg`]: { body: "fixture disk image" }
  }
  writeFileSync(join(root, "responses.json"), JSON.stringify(responses))
  mkdirSync(join(root, "home", "alice"), { recursive: true })
  writeFileSync(join(root, "passwd"), `alice:x:1001:1001::${join(root, "home", "alice")}:/bin/sh\n`)
  const requests = join(root, "requests.jsonl")
  const services = join(root, "services.log")
  writeFileSync(requests, "")
  writeFileSync(services, "")
  for (const [path, text] of Object.entries(options.files ?? {})) {
    mkdirSync(join(root, path, ".."), { recursive: true })
    writeFileSync(join(root, path), text)
  }
  if (options.loginctl !== undefined) {
    writeFileSync(join(bin, "loginctl"), `#!/bin/sh\nset -eu\n${options.loginctl}\n`, {
      mode: 0o755
    })
  }
  if (options.systemctl !== undefined) {
    writeFileSync(join(bin, "systemctl"), `#!/bin/sh\nset -eu\n${options.systemctl}\n`, {
      mode: 0o755
    })
  }
  const result = await runShell(installer, options.args ?? [], {
    detached: true,
    env: {
      PATH: `${bin}:${sharedCommands}:/usr/bin:/bin`,
      HOME: root,
      USER: "installer-test",
      LC_ALL: "C",
      TMPDIR: root,
      CODEVISOR_INSTALL_DIR: runtime,
      CODEVISOR_BIN_DIR: join(root, "bin"),
      CODEVISOR_DATA_DIR: options.defaultDataDir ? undefined : join(root, "data"),
      CODEVISOR_NO_SETUP: "1",
      TEST_ROOT: root,
      TEST_REQUESTS: requests,
      TEST_SERVICES: services,
      TEST_PLATFORM: options.platform ?? "Linux",
      TEST_ARCH: architecture,
      TEST_UID: String(options.uid ?? 1000),
      ...options.env
    }
  })
  assert.ifError(result.error)
  return {
    ...result,
    root,
    runtime,
    requests: readFileSync(requests, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse),
    services: readFileSync(services, "utf8")
  }
}
