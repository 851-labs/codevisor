import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { existsSync, readFileSync } from "node:fs"
import { join } from "node:path"
import test, { describe } from "node:test"

import { downloadBase, install, stableURL } from "./install-test-support.mjs"

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
      `alice ${home} auth login --invite -\nalice ${home} desktop setup --help\n`
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
        "args=start",
        "stdin=",
        "env=",
        "args=auth login --invite - --name hetzner 1",
        "stdin=cvi1.aHR0cHM6Ly9jbG91ZC5leGFtcGxl.secret",
        "env=",
        "args=desktop setup --help",
        "stdin=",
        "env=",
        ""
      ].join("\n")
    )
  })

  test("a systemd user manager that can't start installs without a service, then joins", async (t) => {
    const result = await install(t, {
      uid: 0,
      cli: 'printf "args=%s\\n" "$*" >> "$TEST_ROOT/cli.log"',
      loginctl: 'echo "Failed to connect to bus: No such file or directory" >&2; exit 1',
      env: { CODEVISOR_INVITE: "cvi1.aHR0cHM6Ly9jbG91ZC5leGFtcGxl.secret" }
    })
    assert.equal(result.status, 0, result.stderr)
    assert.match(result.stdout, /Start it with:/)
    assert.doesNotMatch(result.services, /restart codevisor-server\.service/)
    assert.equal(
      readFileSync(join(result.root, "cli.log"), "utf8"),
      "args=start\nargs=auth login --invite -\nargs=desktop setup --help\n"
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
      "args=start --port 5000\nargs=auth login --invite - --port 5000\nargs=desktop setup --help\n"
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
    assert.equal(
      readFileSync(join(result.root, "cli.log"), "utf8"),
      "called desktop setup --help\n"
    )
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

  for (const archiveBase of [undefined, "http://192.0.2.10:8123"]) {
    test(`Apple silicon installs the headless server from ${archiveBase ?? "the release"}`, async (t) => {
      const result = await install(t, {
        platform: "Darwin",
        architecture: "arm64",
        archiveBase,
        env: { CODEVISOR_INSTALL_SERVER: "1", CODEVISOR_SERVER_ARCHIVE_BASE: archiveBase }
      })
      assert.equal(result.status, 0, result.stderr)
      const archive = `${archiveBase ?? `${downloadBase}/v0.1.99`}/codevisor-server-darwin-arm64.tar.gz`
      assert.deepEqual(
        result.requests.map(({ url }) => url),
        [stableURL, archive, `${archive}.sha256`]
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
