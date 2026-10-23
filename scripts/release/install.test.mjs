import assert from "node:assert/strict"
import { execFileSync, spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test, { after, describe } from "node:test"

const installer = readFileSync(new URL("../../apps/www/public/install.sh", import.meta.url), "utf8")
const stableURL = "https://updates.codevisor.dev/server/stable.json"
const githubLatestURL = "https://api.github.com/repos/851-labs/codevisor/releases/latest"
const downloadBase = "https://github.com/851-labs/codevisor/releases/download"

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

const install = async (t, options = {}) => {
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
  const archiveURL = `${downloadBase}/v${version}/codevisor-server-${target}.tar.gz`
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

describe("install.sh", { concurrency: true }, () => {
  test("Linux keeps server data in the installing account's home", async (t) => {
    const result = await install(t, { defaultDataDir: true, env: { CODEVISOR_NO_SERVICE: "1" } })
    assert.equal(result.status, 0, result.stderr)
    assert.ok(existsSync(join(result.root, ".codevisor", "data")))
    assert.ok(existsSync(join(result.root, ".codevisor", "logs")))
    assert.equal(result.services, "")
  })

  test("through sudo, the invoking account runs a lingering user service", async (t) => {
    const cli = 'printf "%s %s %s\\n" "$USER" "$HOME" "$*" >> "$TEST_ROOT/cli.log"'
    const result = await install(t, {
      uid: 0,
      cli,
      defaultDataDir: true,
      env: {
        SUDO_USER: "alice",
        CODEVISOR_INVITE: "cvi1.aHR0cHM6Ly9jbG91ZC5leGFtcGxl.secret"
      }
    })
    assert.equal(result.status, 0, result.stderr)
    const home = join(result.root, "home", "alice")
    assert.match(result.stdout, /codevisor-server will run as alice/)
    assert.ok(existsSync(join(home, ".codevisor", "data")))
    assert.match(
      readFileSync(join(home, ".config", "systemd", "user", "codevisor-server.service"), "utf8"),
      /--db ".*\/home\/alice\/\.codevisor\/data\/codevisor-server\.sqlite"/
    )
    assert.match(result.services, /^loginctl enable-linger alice$/m)
    assert.match(result.services, /^--user restart codevisor-server\.service$/m)
    assert.doesNotMatch(result.services, /useradd|tee/)
    const runuser = readFileSync(join(result.root, "runuser.log"), "utf8")
    assert.match(runuser, /as alice: .*XDG_RUNTIME_DIR=\/run\/user\/1001 systemctl --user restart/)
    assert.doesNotMatch(runuser, /^as (?!alice:)/m)
    assert.equal(
      readFileSync(join(result.root, "cli.log"), "utf8"),
      `alice ${home} auth login --invite -\n`
    )
  })

  test("a root shell creates a codevisor account with passwordless sudo", async (t) => {
    const result = await install(t, { uid: 0, defaultDataDir: true })
    assert.equal(result.status, 0, result.stderr)
    assert.match(result.services, /^useradd .*--create-home .* codevisor$/m)
    assert.match(
      result.services,
      /^tee \/etc\/sudoers\.d\/codevisor: codevisor ALL=\(ALL\) NOPASSWD:ALL$/m
    )
    assert.match(result.services, /^loginctl enable-linger codevisor$/m)
    assert.ok(existsSync(join(result.root, "home", "codevisor", ".codevisor", "data")))
  })

  test("--user picks the account over the invoking one", async (t) => {
    const result = await install(t, {
      uid: 0,
      args: ["--user", "alice"],
      env: { SUDO_USER: "bob", CODEVISOR_NO_SERVICE: "1" }
    })
    assert.equal(result.status, 0, result.stderr)
    assert.match(result.stdout, /codevisor-server will run as alice/)
    assert.match(result.stdout, /su - alice -c 'codevisor start'/)
  })

  for (const { name, args, uid, message } of [
    { name: "root", args: ["--user", "root"], uid: 0, message: /can't run as root/ },
    {
      name: "a missing account",
      args: ["--user=nobody"],
      uid: 0,
      message: /no account named nobody/
    },
    {
      name: "another account without root",
      args: ["--user", "alice"],
      uid: 1000,
      message: /needs root/
    }
  ]) {
    test(`--user refuses ${name} before installing`, async (t) => {
      const result = await install(t, { uid, args })
      assert.equal(result.status, 1)
      assert.match(result.stderr, message)
      assert.equal(existsSync(join(result.runtime, "old-runtime")), true)
      assert.equal(result.services, "")
    })
  }

  test("an invite joins the account without a prompt, passing the code on stdin", async (t) => {
    const cli = [
      'printf "args=%s\\n" "$*" >> "$TEST_ROOT/cli.log"',
      'printf "stdin=%s\\n" "$(cat)" >> "$TEST_ROOT/cli.log"',
      'printf "env=%s\\n" "${CODEVISOR_INVITE:-}" >> "$TEST_ROOT/cli.log"'
    ].join("\n")
    const result = await install(t, {
      cli,
      env: {
        CODEVISOR_NO_SERVICE: "1",
        CODEVISOR_INVITE: "cvi1.aHR0cHM6Ly9jbG91ZC5leGFtcGxl.secret",
        CODEVISOR_MACHINE_NAME: "hetzner 1"
      }
    })
    assert.equal(result.status, 0, result.stderr)
    assert.equal(
      readFileSync(join(result.root, "cli.log"), "utf8"),
      [
        "args=auth login --invite - --name hetzner 1",
        "stdin=cvi1.aHR0cHM6Ly9jbG91ZC5leGFtcGxl.secret",
        "env=",
        ""
      ].join("\n")
    )
  })

  test("onboarding pins the port only when the installer was given one", async (t) => {
    const result = await install(t, {
      cli: 'printf "args=%s\\n" "$*" >> "$TEST_ROOT/cli.log"',
      env: {
        CODEVISOR_NO_SERVICE: "1",
        CODEVISOR_INVITE: "cvi1.aHR0cHM6Ly9jbG91ZC5leGFtcGxl.secret",
        CODEVISOR_PORT: "5000"
      }
    })
    assert.equal(result.status, 0, result.stderr)
    assert.equal(
      readFileSync(join(result.root, "cli.log"), "utf8"),
      "args=auth login --invite - --port 5000\n"
    )
  })

  test("a systemctl without a running systemd (containers, WSL) installs without a service", async (t) => {
    const result = await install(t, {
      systemctl: [
        'case "$1" in show) echo "System has not been booted with systemd" >&2; exit 1;; esac',
        'printf "%s\\n" "$*" >> "$TEST_SERVICES"'
      ].join("\n")
    })
    assert.equal(result.status, 0, result.stderr)
    assert.equal(result.services, "")
    assert.match(result.stdout, /codevisor start/)
  })

  test("without an invite or a terminal, the installer only prints how to finish", async (t) => {
    const cli = 'printf "called %s\\n" "$*" >> "$TEST_ROOT/cli.log"'
    const result = await install(t, {
      cli,
      env: { CODEVISOR_NO_SERVICE: "1", CODEVISOR_NO_SETUP: "0" }
    })
    assert.equal(result.status, 0, result.stderr)
    assert.equal(existsSync(join(result.root, "cli.log")), false)
    assert.match(result.stdout, /codevisor setup/)
  })

  for (const architecture of ["x86_64", "aarch64"]) {
    test(`Linux ${architecture} installs current stable despite a stale GitHub latest pointer`, async (t) => {
      const result = await install(t, { architecture })
      assert.equal(result.status, 0, result.stderr)
      assert.match(result.stdout, /Installing codevisor-server 0\.1\.99/)
      assert.match(result.stdout, /Checksum verified/)
      assert.equal(existsSync(join(result.runtime, "old-runtime")), false)
      for (const command of ["codevisor", "codevisor-server", "codevisor-terminal-proxy"]) {
        assert.equal(
          execFileSync(join(result.root, "bin", command), { encoding: "utf8" }),
          "codevisor 0.1.99\n"
        )
      }
      assert.deepEqual(
        result.requests.map(({ url }) => url),
        [
          stableURL,
          `${downloadBase}/v0.1.99/codevisor-server-linux-${architecture === "aarch64" ? "arm64" : "x64"}.tar.gz`,
          `${downloadBase}/v0.1.99/codevisor-server-linux-${architecture === "aarch64" ? "arm64" : "x64"}.tar.gz.sha256`
        ]
      )
      assert.ok(result.requests[0].args.includes("Cache-Control: no-cache"))
      assert.match(result.services, /--user restart codevisor-server\.service/)
    })
  }

  for (const manifest of [
    '{"targets":{},"version":"0.1.99","buildNumber":422}',
    '{\n  "version":\n    "v0.1.99"\n}'
  ]) {
    test(`accepts stable manifest formatting: ${JSON.stringify(manifest)}`, async (t) => {
      const result = await install(t, { manifest })
      assert.equal(result.status, 0, result.stderr)
      assert.match(result.stdout, /Installing codevisor-server 0\.1\.99/)
    })
  }

  for (const [name, options] of Object.entries({
    "unavailable feed": { manifestStatus: 22 },
    "missing version": { manifest: '{"buildNumber":422}' },
    "empty response": { manifest: "" },
    "HTML error": { manifest: "<html>Unavailable</html>" },
    "invalid version": { manifest: '{"version":"0.1"}' },
    "alpha version": { manifest: '{"version":"0.1.100-alpha.493"}' }
  })) {
    test(`${name} fails before changing the installation without falling back to GitHub`, async (t) => {
      const result = await install(t, options)
      assert.equal(result.status, 1)
      assert.match(result.stderr, /stable.*https:\/\/updates\.codevisor\.dev\/server\/stable\.json/)
      assert.match(result.stderr, /CODEVISOR_VERSION/)
      assert.deepEqual(
        result.requests.map(({ url }) => url),
        [stableURL]
      )
      assert.equal(existsSync(join(result.runtime, "old-runtime")), true)
      assert.equal(result.services, "")
    })
  }

  for (const { name, env, expectedVersion } of [
    { name: "explicit stable", env: { CODEVISOR_VERSION: "0.1.98" }, expectedVersion: "0.1.98" },
    {
      name: "explicit alpha with v prefix",
      env: { CODEVISOR_VERSION: "v0.1.100-alpha.493" },
      expectedVersion: "0.1.100-alpha.493"
    },
    { name: "legacy pin", env: { HERDMAN_VERSION: "v0.1.97" }, expectedVersion: "0.1.97" },
    {
      name: "modern pin takes precedence",
      env: { CODEVISOR_VERSION: "0.1.98", HERDMAN_VERSION: "0.1.97" },
      expectedVersion: "0.1.98"
    }
  ]) {
    test(`${name} bypasses the stable feed, even when it is unavailable`, async (t) => {
      const result = await install(t, { env, expectedVersion, manifestStatus: 22 })
      assert.equal(result.status, 0, result.stderr)
      assert.ok(result.stdout.includes(`Installing codevisor-server ${expectedVersion}`))
      assert.equal(result.requests.length, 2)
      assert.ok(
        result.requests.every(({ url }) => url.startsWith(`${downloadBase}/v${expectedVersion}/`))
      )
    })
  }

  for (const [name, env] of Object.entries({
    "a native shell": {},
    "a Rosetta shell": { TEST_HW_ARM64: "1" }
  })) {
    test(`Apple silicon under ${name} installs the arm64 app`, async (t) => {
      const architecture = env.TEST_HW_ARM64 === undefined ? "arm64" : "x86_64"
      const result = await install(t, { platform: "Darwin", architecture, env })
      assert.equal(result.status, 71, result.stderr)
      assert.doesNotMatch(result.stdout, /not supported on Intel/)
      assert.deepEqual(
        result.requests.map(({ url }) => url),
        [stableURL, `${downloadBase}/v0.1.99/Codevisor-arm64.dmg`]
      )
    })
  }

  test("Intel Mac installs the standalone darwin-x64 server once confirmed", async (t) => {
    const result = await install(t, {
      platform: "Darwin",
      architecture: "x86_64",
      env: { CODEVISOR_INSTALL_SERVER: "1" }
    })
    assert.equal(result.status, 0, result.stderr)
    assert.match(result.stdout, /Codevisor app is not supported on Intel Macs/)
    assert.match(result.stdout, /Installing codevisor-server 0\.1\.99 \(darwin-x64\)/)
    assert.match(result.stdout, /Checksum verified/)
    assert.match(result.stdout, /codevisor start/)
    assert.deepEqual(
      result.requests.map(({ url }) => url),
      [
        stableURL,
        `${downloadBase}/v0.1.99/codevisor-server-darwin-x64.tar.gz`,
        `${downloadBase}/v0.1.99/codevisor-server-darwin-x64.tar.gz.sha256`
      ]
    )
    assert.equal(
      execFileSync(join(result.root, "bin", "codevisor"), { encoding: "utf8" }),
      "codevisor 0.1.99\n"
    )
    assert.doesNotMatch(result.services, /codevisor-server\.service/)
  })

  for (const { name, env, message } of [
    { name: "without a terminal to confirm", env: {}, message: /CODEVISOR_INSTALL_SERVER=1/ },
    {
      name: "when declined",
      env: { CODEVISOR_INSTALL_SERVER: "0" },
      message: /not installing codevisor-server/
    }
  ]) {
    test(`Intel Mac installs nothing ${name}`, async (t) => {
      const result = await install(t, { platform: "Darwin", architecture: "x86_64", env })
      assert.equal(result.status, 1)
      assert.match(result.stdout, /Codevisor app is not supported on Intel Macs/)
      assert.match(result.stderr, message)
      assert.deepEqual(result.requests, [])
      assert.equal(existsSync(join(result.runtime, "old-runtime")), true)
    })
  }
})
